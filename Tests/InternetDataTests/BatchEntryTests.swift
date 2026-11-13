import Foundation
import Testing

@testable import InternetData

// The generated decoder reads a chunk's whole answer, so one entry it could not
// read would fail every address in the chunk, sent three times. Each entry is
// read on its own.
@Suite("A batch answer read entry by entry")
struct BatchEntryTests {
    nonisolated(unsafe) static let good: [String: Any] = {
        var answer = StubTransport.answer(for: "45.83.91.2")
        answer["is_vpn"] = true
        answer["vpn"] = [
            "provider": "mullvad", "provider_name": "Mullvad", "confidence": "high", "last_seen": "2026-11-13",
        ]
        return answer
    }()

    @Test("an entry it cannot read fails that address alone, sent once")
    func anUnreadableEntryFailsThatAddressAlone() async throws {
        func entry(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            var answer = StubTransport.answer(for: "45.83.91.1")
            change(&answer)
            return answer
        }
        let entries: [(String, Any)] = [
            ("asn.asn of \"3\"", entry {
                $0["asn"] = ["asn": "3", "name": "", "domain": "", "type": "", "prefix": ""]
            }),
            ("is_tor of \"yes\"", entry { $0["is_tor"] = "yes" }),
            ("pubproxy.protocols of [null]", entry {
                $0["pubproxy"] = [
                    "entry": true, "exit": false, "protocols": [NSNull()], "num_ports": 1, "num_proxies": 0,
                    "last_seen": "", "last_usable": "",
                ]
            }),
            ("web of [null]", entry { $0["web"] = [NSNull()] }),
            ("no hostname", entry { $0["hostname"] = nil }),
            ("an entry of {}", [String: Any]()),
            ("an entry of null", NSNull()),
            ("an entry of \"x\"", "x"),
        ]
        for (name, entry) in entries {
            let stub = Self.serving(["results": ["45.83.91.1": entry, "45.83.91.2": Self.good], "errors": [:]])
            let results = try await Self.client(stub).lookupBatch(["45.83.91.1", "45.83.91.2"])
            Self.expectUnreadable(results["45.83.91.1"], name)
            guard case .success(let served) = results["45.83.91.2"] else {
                Issue.record("the good entry beside \(name) failed")
                continue
            }
            #expect(served.vpn?.provider == "mullvad", "\(name)")
            await #expect(stub.callCount == 1, "\(name)")
        }
    }

    @Test("an entry error it cannot read fails that address alone, sent once")
    func anUnreadableEntryErrorFailsThatAddressAlone() async throws {
        let entries: [(String, Any)] = [
            ("a status of \"x\"", ["status": "x", "error": "failed"]),
            ("an error of null", NSNull()),
            ("an error of []", [Any]()),
        ]
        for (name, entry) in entries {
            let stub = Self.serving(["results": ["45.83.91.2": Self.good], "errors": ["45.83.91.1": entry]])
            let results = try await Self.client(stub).lookupBatch(["45.83.91.1", "45.83.91.2"])
            Self.expectUnreadable(results["45.83.91.1"], name)
            guard case .success = results["45.83.91.2"] else {
                Issue.record("the good entry beside \(name) failed")
                continue
            }
            await #expect(stub.callCount == 1, "\(name)")
        }
        let stub = Self.serving(["results": [:], "errors": ["45.83.91.1": ["status": 404, "error": "not found"]]])
        let results = try await Self.client(stub).lookupBatch(["45.83.91.1"])
        guard case .failure(let error) = results["45.83.91.1"] else {
            Issue.record("a readable entry error came back as an answer")
            return
        }
        #expect(error.kind == .badRequest)
        #expect(error.status == 404)
        #expect(error.message == "not found")
    }

    @Test("a chunk holding neither map fails every address in it, retried")
    func aChunkHoldingNeitherMapFailsEveryAddress() async throws {
        let bodies: [(String, Data)] = [
            ("{}", Data("{}".utf8)),
            ("[]", Data("[]".utf8)),
            ("null", Data("null".utf8)),
            ("an HTML page", Data("<html>gateway</html>".utf8)),
            ("results of []", Data(#"{"results":[],"errors":{}}"#.utf8)),
            ("a cut-off body", Data(#"{"results":{"45.83.91.2":{"ip":"#.utf8)),
        ]
        for (name, body) in bodies {
            let stub = StubTransport(["batch": .init(status: 200, body: body)])
            let results = try await Self.client(stub).lookupBatch(["45.83.91.1", "45.83.91.2"])
            Self.expectUnreadable(results["45.83.91.1"], name)
            Self.expectUnreadable(results["45.83.91.2"], name)
            await #expect(stub.callCount == 3, "\(name)")
        }
    }

    @Test("one map alone is read, an address in neither a server error")
    func oneMapAloneIsRead() async throws {
        let stub = Self.serving(["results": ["45.83.91.2": Self.good]])
        let results = try await Self.client(stub).lookupBatch(["45.83.91.1", "45.83.91.2"])
        guard case .success = results["45.83.91.2"] else {
            Issue.record("a chunk without errors lost its result")
            return
        }
        Self.expectUnreadable(results["45.83.91.1"], "an address in neither map")
        await #expect(stub.callCount == 1)
    }

    static func serving(_ body: [String: Any]) -> StubTransport {
        StubTransport(["batch": .json(body)])
    }

    static func client(_ stub: StubTransport) -> InternetDataClient {
        InternetDataClient(options: .init(apiKey: "key", cache: nil, retries: 2, transport: stub))
    }

    static func expectUnreadable(_ outcome: BatchResults.Outcome?, _ name: String) {
        guard case .failure(let error) = outcome else {
            Issue.record("\(name) came back as an answer")
            return
        }
        #expect(error.kind == .serverError, "\(name)")
        #expect(error.status == 200, "\(name)")
    }
}
