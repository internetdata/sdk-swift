/// What a batch answers: one outcome per address, in the order you passed them.
///
/// Keyed by address rather than positional, so duplicates in the input collapse
/// to a single request and you never have to line two lists up. An address that
/// failed carries its error as its value, so one bad entry cannot lose the rest
/// of the answers.
///
/// `Dictionary` makes no promise about iteration order and Swift has no ordered
/// dictionary in the standard library, so this holds the input order alongside
/// the lookup table rather than taking a dependency for one type.
public struct BatchResults: Sendable, Hashable {
    /// Either the answer or the reason there is none.
    public typealias Outcome = Swift.Result<LookupResult, InternetDataError>

    /// The addresses, deduplicated, in the order they were passed in.
    public let keys: [String]
    private let outcomes: [String: Outcome]

    public subscript(ip: String) -> Outcome? { outcomes[ip] }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// The successful answers only, in input order.
    public var values: [LookupResult] {
        keys.compactMap { try? outcomes[$0]?.get() }
    }

    /// The addresses that failed, with their errors, in input order.
    public var failures: [(ip: String, error: InternetDataError)] {
        keys.compactMap { ip in
            guard case .failure(let error) = outcomes[ip] else {
                return nil
            }
            return (ip, error)
        }
    }

    init(keys: [String], outcomes: [String: Outcome]) {
        self.keys = keys
        self.outcomes = outcomes
    }
}

extension BatchResults: Sequence {
    public func makeIterator() -> AnyIterator<(ip: String, outcome: Outcome)> {
        var index = keys.startIndex
        return AnyIterator {
            while index < self.keys.endIndex {
                let ip = self.keys[index]
                index = self.keys.index(after: index)
                if let outcome = self.outcomes[ip] {
                    return (ip, outcome)
                }
            }
            return nil
        }
    }
}
