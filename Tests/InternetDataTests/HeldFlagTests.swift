import Foundation
import Testing

@testable import InternetData

// Unlimited's answer stopped carrying eight flags on 2026-11-26. They stay `Bool`
// until the next major, so an answer without one reads false and one with it
// reads as served, and what was refused for a present flag is refused still.
@Suite("The eight flags Unlimited does not answer")
struct HeldFlagTests {
    static let flags: [(String, @Sendable (LookupResult) -> Bool)] = [
        ("is_bot", { $0.isBot }), ("is_carrier", { $0.isCarrier }), ("is_satellite", { $0.isSatellite }),
        ("is_ssh", { $0.isSsh }), ("is_smtp", { $0.isSmtp }), ("is_web", { $0.isWeb }),
        ("is_dns_resolver", { $0.isDnsResolver }), ("is_bittorrent", { $0.isBittorrent }),
    ]

    @Test("the library holds the same eight the conformance runner does")
    func theListsAgree() {
        #expect(Set(HeldFlags.names) == Set(ConformanceTests.heldFlags))
        #expect(Set(Self.flags.map(\.0)) == Set(ConformanceTests.heldFlags))
    }

    @Test("an answer without them reads each false and the rows behind them nil, on every lookup")
    func absentReadsFalse() async throws {
        let answer = StubTransport.answer(for: "1.1.1.1")
        for name in ConformanceTests.heldFlags {
            #expect(answer[name] == nil, "\(name) is in the stub's Unlimited answer")
        }
        let stub = StubTransport([
            "1.1.1.1": .json(answer), "myip": .json(answer),
            "8.8.8.8": .json(StubTransport.answer(for: "8.8.8.8")),
        ])
        let client = Self.client(stub)

        let batch = try await client.lookupBatch(["8.8.8.8"])
        let results = [
            try await client.lookup("1.1.1.1"), try await client.myIP(), try #require(batch["8.8.8.8"]).get(),
        ]
        for result in results {
            for (name, read) in Self.flags {
                #expect(read(result) == false, "\(name) of \(result.ip)")
            }
            #expect(result.bot == nil && result.carrier == nil && result.satellite == nil)
            #expect(result.ssh == nil && result.smtp == nil && result.web == nil)
            #expect(result.dnsResolver == nil && result.bittorrent == nil)
            #expect(result.isHosting == nil, "a member held optional stays absent")
        }
    }

    @Test("each reads as served, true or false, and leaves the others as they were")
    func presentReadsAsServed() async throws {
        for (name, read) in Self.flags {
            for served in [true, false] {
                var answer = StubTransport.answer(for: "1.1.1.1")
                answer[name] = served
                let stub = StubTransport(["1.1.1.1": .json(answer)])

                let result = try await Self.client(stub).lookup("1.1.1.1")

                #expect(read(result) == served, "\(name) served \(served)")
                for (other, readOther) in Self.flags where other != name {
                    #expect(readOther(result) == false, "\(other) beside \(name) served \(served)")
                }
            }
        }
    }

    // What a present flag may not be is the spec's, as it was while the flag was required.
    @Test("a flag served as anything but a boolean is a retried server error, a batch entry's alone")
    func aPresentFlagOfAnotherTypeIsRefused() async throws {
        let wrong: [(String, Any)] = [
            ("\"yes\"", "yes"), ("1", 1), ("null", NSNull()), ("[]", [Any]()), ("{}", [String: Any]()),
        ]
        for (name, _) in Self.flags {
            for (shown, value) in wrong {
                let label = "\(name) of \(shown)"
                var bad = StubTransport.answer(for: "45.83.91.1")
                bad[name] = value

                let single = StubTransport(["45.83.91.1": .json(bad), "myip": .json(bad)])
                let calls: [@Sendable (InternetDataClient) async throws -> Void] = [
                    { _ = try await $0.lookup("45.83.91.1") },
                    { _ = try await $0.myIP() },
                ]
                for call in calls {
                    let failure = await #expect(throws: InternetDataError.self, "\(label)") {
                        try await call(Self.client(single, retries: 0))
                    }
                    #expect(try #require(failure).kind == .serverError, "\(label)")
                    #expect(try #require(failure).status == 200, "\(label)")
                    #expect(try #require(failure).isRetryable, "\(label)")
                }
                await #expect(single.callCount == 2, "\(label): one request for each call")

                let batch = StubTransport([
                    "45.83.91.1": .json(bad), "45.83.91.2": .json(StubTransport.answer(for: "45.83.91.2")),
                ])
                let results = try await Self.client(batch).lookupBatch(["45.83.91.1", "45.83.91.2"])
                guard case .failure(let error) = results["45.83.91.1"] else {
                    Issue.record("\(label): the entry came back as an answer")
                    continue
                }
                #expect(error.kind == .serverError && error.status == 200, "\(label)")
                guard case .success = results["45.83.91.2"] else {
                    Issue.record("\(label): the entry beside it failed")
                    continue
                }
                await #expect(batch.callCount == 1, "\(label): a batch entry is not sent again")
            }
        }
    }

    @Test("a refused flag is retried like any other unreadable answer")
    func aRefusedFlagIsRetried() async throws {
        var bad = StubTransport.answer(for: "45.83.91.1")
        bad["is_bot"] = NSNull()
        let stub = StubTransport(["45.83.91.1": .json(bad)])

        await #expect(throws: InternetDataError.self) {
            try await Self.client(stub, retries: 2).lookup("45.83.91.1")
        }

        await #expect(stub.callCount == 3)
    }

    // The shared AS object answers `type` on a paid plan or the trial since spec 2026.11.26.
    @Test("an AS without its type reads it empty, and one served as a number is refused")
    func asnTypeIsHeldAsString() async throws {
        var answer = StubTransport.answer(for: "1.1.1.1")
        var asn = try #require(answer["asn"] as? [String: Any])
        asn["type"] = nil
        answer["asn"] = asn
        let result = try await Self.client(StubTransport(["1.1.1.1": .json(answer)])).lookup("1.1.1.1")
        #expect(result.asn.type == "")
        #expect(result.asn.name == "M247 Europe SRL")

        asn["type"] = 3
        answer["asn"] = asn
        let stub = StubTransport(["1.1.1.1": .json(answer)])
        let failure = await #expect(throws: InternetDataError.self) {
            try await Self.client(stub, retries: 0).lookup("1.1.1.1")
        }
        #expect(try #require(failure).kind == .serverError)
    }

    static func client(_ stub: StubTransport, retries: Int = 2) -> InternetDataClient {
        InternetDataClient(options: .init(apiKey: "key", cache: nil, retries: retries, transport: stub))
    }
}
