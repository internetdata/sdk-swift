import Foundation
import Testing

@testable import InternetData

/// A spent trial's or a reached cap's answer ends with a new UTC day or a raised
/// cap, so it is cached for a minute at most rather than the client's TTL.
@Suite("Cache life")
struct CacheLifeTests {
    static let answers: [String: StubTransport.Route] = [
        "8.8.8.8": .json(StubTransport.answer(for: "8.8.8.8")),
        "9.9.9.9": .json(
            StubTransport.answer(for: "9.9.9.9").merging(["trial_expired": false, "cap_reached": false]) { $1 }
        ),
        "8.8.4.4": .json(StubTransport.answer(for: "8.8.4.4").merging(["trial_expired": true]) { $1 }),
        "1.0.0.1": .json(StubTransport.answer(for: "1.0.0.1").merging(["cap_reached": true]) { $1 }),
    ]

    @Test(
        "each answer stays as long as its flags allow",
        arguments: [
            ("8.8.8.8", 3600, 3600),
            ("9.9.9.9", 3600, 3600),
            ("8.8.4.4", 3600, 60),
            ("1.0.0.1", 3600, 60),
            ("8.8.4.4", 10, 10),
            ("1.0.0.1", 10, 10),
            ("8.8.8.8", 10, 10),
        ],
    )
    func answerLife(_ ip: String, _ ttl: Int, _ want: Int) async throws {
        let client = InternetDataClient(options: .init(transport: StubTransport(Self.answers)))
        let result = try await client.lookup(ip)
        let cache = ResultCache(CacheOptions(ttl: .seconds(ttl)))

        let before = ContinuousClock.now
        await cache.set(ip, result)
        let after = ContinuousClock.now
        let expiry = try #require(await cache.expiry(ip))

        #expect(expiry >= before.advanced(by: .seconds(want)), "\(ip) under a \(ttl) s TTL")
        #expect(expiry <= after.advanced(by: .seconds(want)), "\(ip) under a \(ttl) s TTL")
    }

    @Test("a client caches a reduced answer, so a repeat sends nothing")
    func reducedAnswerIsCached() async throws {
        let stub = StubTransport(Self.answers)
        let client = InternetDataClient(options: .init(transport: stub))

        _ = try await client.lookup("8.8.4.4")
        let again = try await client.lookup("8.8.4.4")

        #expect(again.trialExpired == true)
        #expect(await stub.callCount == 1)
    }
}
