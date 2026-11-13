import Foundation

/// How the per-client answer cache behaves.
public struct CacheOptions: Sendable, Hashable {
    /// Maximum number of addresses held. Default 10000.
    public var maxEntries: Int
    /// How long an answer stays fresh. Default 1 hour.
    public var ttl: Duration

    public init(maxEntries: Int = 10_000, ttl: Duration = .seconds(3600)) {
        self.maxEntries = maxEntries
        self.ttl = ttl
    }
}

/// A least-recently-used cache with a time to live, keyed by address.
///
/// One instance per client, never global: two clients with different keys are on
/// different plans and entitled to different fields, so a shared cache would
/// serve one of them the other's shape. An actor rather than a lock because the
/// cache is the ONLY mutable state in the library, and isolating it is what lets
/// ``InternetDataClient`` stay a plain `Sendable` struct whose methods run on the
/// caller's executor.
///
/// Hand-rolled rather than taken from a dependency: nothing in the Swift package
/// ecosystem is the blessed LRU (NSCache has no TTL and no deterministic
/// eviction, and is unreliable on Linux), and an intrusive list over a
/// dictionary is a few dozen lines for O(1) reads, writes and evictions.
actor ResultCache {
    private let maxEntries: Int
    private let ttl: Duration
    private var entries: [String: Node] = [:]
    private var head: Node?
    private var tail: Node?
    // The addresses with a request in flight, so a concurrent miss waits for that
    // request instead of sending its own. Here rather than in a coalescing getter
    // because a batch must know which addresses it leads BEFORE it builds chunks.
    private var flights: [String: Flight] = [:]
    private var tickets: [UUID: Ticket] = [:]

    init(_ options: CacheOptions) {
        precondition(options.maxEntries > 0, "cache maxEntries must be positive")
        precondition(options.ttl > .zero, "cache ttl must be positive")
        self.maxEntries = options.maxEntries
        self.ttl = options.ttl
    }

    func get(_ ip: String) -> LookupResult? {
        guard let node = entries[ip] else {
            return nil
        }
        guard node.expires > ContinuousClock.now else {
            remove(node)
            return nil
        }
        promote(node)
        return node.result
    }

    func set(_ ip: String, _ result: LookupResult) {
        if let existing = entries[ip] {
            existing.result = result
            existing.expires = ContinuousClock.now.advanced(by: ttl)
            promote(existing)
            return
        }
        let node = Node(ip: ip, result: result, expires: ContinuousClock.now.advanced(by: ttl))
        entries[ip] = node
        prepend(node)
        if entries.count > maxEntries, let oldest = tail {
            remove(oldest)
        }
    }

    /// The answer to `ip` if it is fresh, or else whether this caller sends the
    /// request (``Claim/lead(_:)``, landed with ``land(_:_:_:)``) or waits for the
    /// one already in flight (``Claim/wait(_:)``, collected with ``collect(_:)``).
    func claim(_ ip: String) -> Claim {
        if let hit = get(ip) {
            return .hit(hit)
        }
        if var flight = flights[ip] {
            let ticket = UUID()
            tickets[ticket] = Ticket()
            flight.tickets.append(ticket)
            flights[ip] = flight
            return .wait(ticket)
        }
        let flight = Flight()
        flights[ip] = flight
        return .lead(flight.id)
    }

    /// ``claim(_:)`` for every address at once, so a batch boards the addresses it
    /// sends before a lookup arriving meanwhile can start a request of its own.
    func board(_ ips: [String]) -> [String: Claim] {
        var claims: [String: Claim] = [:]
        for ip in ips {
            claims[ip] = claim(ip)
        }
        return claims
    }

    /// Ends the flight `flight` for `ip`, caching a served answer and handing the
    /// landing to every waiter. A flight that already landed is left alone, so a
    /// leader can abandon everything it led without checking what landed.
    func land(_ ip: String, _ flight: UUID, _ landing: Landing) {
        guard let current = flights[ip], current.id == flight else {
            return
        }
        flights[ip] = nil
        if case .served(let result) = landing {
            set(ip, result)
        }
        for id in current.tickets {
            guard var ticket = tickets[id] else {
                continue
            }
            if let waiter = ticket.waiter {
                tickets[id] = nil
                waiter.resume(returning: landing)
            } else {
                ticket.landing = landing
                tickets[id] = ticket
            }
        }
    }

    /// How the flight a ``Claim/wait(_:)`` named ended, or ``Landing/cancelled``
    /// once the calling task is cancelled, which leaves the flight to its leader.
    func collect(_ id: UUID) async -> Landing {
        if let landing = tickets[id]?.landing {
            tickets[id] = nil
            return landing
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Landing, Never>) in
                guard !Task.isCancelled, tickets[id] != nil else {
                    tickets[id] = nil
                    waiter.resume(returning: .cancelled)
                    return
                }
                tickets[id]?.waiter = waiter
            }
        } onCancel: {
            Task { await self.drop(id) }
        }
    }

    private func drop(_ id: UUID) {
        tickets.removeValue(forKey: id)?.waiter?.resume(returning: .cancelled)
    }

    private func promote(_ node: Node) {
        guard head !== node else {
            return
        }
        unlink(node)
        prepend(node)
    }

    private func prepend(_ node: Node) {
        node.previous = nil
        node.next = head
        head?.previous = node
        head = node
        if tail == nil {
            tail = node
        }
    }

    private func remove(_ node: Node) {
        unlink(node)
        entries[node.ip] = nil
    }

    private func unlink(_ node: Node) {
        node.previous?.next = node.next
        node.next?.previous = node.previous
        if head === node {
            head = node.next
        }
        if tail === node {
            tail = node.previous
        }
        node.previous = nil
        node.next = nil
    }

    /// What ``claim(_:)`` found for one address.
    enum Claim: Sendable {
        case hit(LookupResult)
        case lead(UUID)
        case wait(UUID)
    }

    /// How a flight ended. A failure reaches every waiter and is cached for none;
    /// an abandoned flight, its leader cancelled, sends each waiter to ask again.
    enum Landing: Sendable {
        case served(LookupResult)
        case failed(any Error)
        case abandoned
        case cancelled
    }

    private struct Flight {
        let id = UUID()
        var tickets: [UUID] = []
    }

    private struct Ticket {
        var landing: Landing?
        var waiter: CheckedContinuation<Landing, Never>?
    }

    // Reference semantics so recency can be reordered without rehashing, and
    // actor isolation keeps every node inside this instance.
    private final class Node {
        let ip: String
        var result: LookupResult
        var expires: ContinuousClock.Instant
        var previous: Node?
        var next: Node?

        init(ip: String, result: LookupResult, expires: ContinuousClock.Instant) {
            self.ip = ip
            self.result = result
            self.expires = expires
        }
    }
}
