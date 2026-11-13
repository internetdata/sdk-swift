import Foundation
import Testing

@testable import InternetData

/// Concurrent misses for one address share one request, a batch's included. Each
/// origin answers after 300 ms, and a second caller arrives 100 ms in.
@Suite("Sharing")
struct SharingTests {
    static let address = "45.83.91.1"
    static let other = "45.83.91.2"

    @Test("concurrent lookups of one address send one request")
    func concurrentLookupsShareOneRequest() async throws {
        let stub = Self.delayed([Self.address])
        let client = Self.client(stub)

        let results = try await withThrowingTaskGroup(of: LookupResult.self) { group in
            for _ in 0..<20 {
                group.addTask { try await client.lookup(Self.address) }
            }
            return try await group.reduce(into: [LookupResult]()) { $0.append($1) }
        }

        #expect(results.count == 20)
        #expect(Set(results.map(\.ip)) == [Self.address])
        #expect(await stub.callCount == 1)
    }

    @Test("without a cache every lookup is served")
    func withoutACacheNothingIsShared() async throws {
        let stub = Self.delayed([Self.address])
        let client = Self.client(stub, cache: nil)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await client.lookup(Self.address) }
            }
            try await group.waitForAll()
        }

        #expect(await stub.callCount == 5)
    }

    @Test("a shared failure reaches every waiter and is cached for none")
    func aFailureReachesEveryWaiter() async throws {
        let stub = StubTransport(
            [Self.address: .json(["error": "boom"], status: 500)], delay: .milliseconds(300),
        )
        let client = Self.client(stub)

        let kinds = await withTaskGroup(of: InternetDataErrorKind?.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        _ = try await client.lookup(Self.address)
                        return nil
                    } catch {
                        return (error as? InternetDataError)?.kind
                    }
                }
            }
            return await group.reduce(into: [InternetDataErrorKind?]()) { $0.append($1) }
        }

        #expect(kinds == Array(repeating: .serverError, count: 5))
        #expect(await stub.callCount == 1)
        _ = try? await client.lookup(Self.address)
        #expect(await stub.callCount == 2, "the failure was cached")
    }

    @Test("a batch waits for a lookup already in flight")
    func aBatchWaitsForALookupInFlight() async throws {
        let stub = Self.delayed([Self.address, Self.other])
        let client = Self.client(stub)

        async let single = client.lookup(Self.address)
        try await Task.sleep(for: .milliseconds(100))
        let batch = try await client.lookupBatch([Self.address, Self.other])

        #expect(try await single.ip == Self.address)
        #expect(try batch[Self.address]?.get().ip == Self.address)
        #expect(await stub.batchIps == [Self.other])
        #expect(await stub.callCount == 2)
    }

    @Test("a lookup waits for a batch already in flight")
    func aLookupWaitsForABatchInFlight() async throws {
        let stub = Self.delayed([Self.address, Self.other])
        let client = Self.client(stub)

        async let batch = client.lookupBatch([Self.address, Self.other])
        try await Task.sleep(for: .milliseconds(100))
        let single = try await client.lookup(Self.address)

        #expect(single.ip == Self.address)
        #expect(try await batch.count == 2)
        #expect(await stub.callCount == 1)
    }

    @Test("a waiter whose leader was cancelled asks again")
    func aCancelledLeaderSendsItsWaiterToAskAgain() async throws {
        let stub = Self.delayed([Self.address])
        let client = Self.client(stub)

        let leader = Task { try await client.lookup(Self.address) }
        try await Task.sleep(for: .milliseconds(100))
        let waiter = Task { try await client.lookup(Self.address) }
        try await Task.sleep(for: .milliseconds(50))
        leader.cancel()

        #expect(try await waiter.value.ip == Self.address)
        #expect(await stub.callCount == 2)
        await #expect(throws: CancellationError.self) { try await leader.value }
    }

    @Test("a cancelled waiter returns at once and leaves the request to its leader")
    func aCancelledWaiterLeavesItsLeader() async throws {
        // The leader lands seconds after the cancel, so a waiter that held on to it is
        // told apart from a slow runner: at 300 ms the gap was 150 ms against a 100 ms
        // bound, and a loaded CI runner took 135 ms.
        let stub = StubTransport(StubTransport.answers(for: [Self.address]), delay: .seconds(2))
        let client = Self.client(stub)

        let leader = Task { try await client.lookup(Self.address) }
        try await Task.sleep(for: .milliseconds(100))
        let waiter = Task { try await client.lookup(Self.address) }
        try await Task.sleep(for: .milliseconds(50))
        let cancelled = ContinuousClock.now
        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(ContinuousClock.now - cancelled < .seconds(1), "the waiter held on to its leader")
        #expect(try await leader.value.ip == Self.address)
        #expect(await stub.callCount == 1)
    }

    static func delayed(_ ips: [String]) -> StubTransport {
        StubTransport(StubTransport.answers(for: ips), delay: .milliseconds(300))
    }

    static func client(_ stub: StubTransport, cache: CacheOptions? = CacheOptions()) -> InternetDataClient {
        InternetDataClient(options: .init(apiKey: "key", cache: cache, retries: 0, transport: stub))
    }
}
