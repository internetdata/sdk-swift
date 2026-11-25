import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import InternetData

/// The user agent a lookup, `myIP` and a batch send, and the verdict an answer
/// carries back. The origin echoes the agent it received as the verdict's
/// `agent`, so an answer cached under the wrong agent reads as one.
@Suite("User agent sent with a lookup")
struct LookupUserAgentTests {
    static let address = "45.83.91.1"
    static let googlebot = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
    static let chrome = "Mozilla/5.0 (X11; Linux x86_64) Chrome/131.0 Safari/537.36"

    @Test("the agent reaches the origin percent-encoded, and the verdict is read")
    func theAgentIsSentEncoded() async throws {
        let origin = AgentOrigin()
        let agent = Self.googlebot + " a&b=c#d?e%f/g;h,i'j"
        let result = try await client(origin).lookup(Self.address, userAgent: agent)

        let raw = try #require(await origin.rawAgents.first ?? nil, "no user_agent reached the origin")
        let encoded = /([A-Za-z0-9\-._~]|%[0-9A-F]{2})*/
        #expect(raw.wholeMatch(of: encoded) != nil, "\(raw) leaves a reserved character raw")
        #expect(raw.contains("%2B"), "the + of \(raw) is not encoded")
        #expect(raw.removingPercentEncoding == agent)
        let verdict = try #require(result.userAgent)
        #expect(verdict.agent == agent)
        #expect(verdict.kind == "bot")
        #expect(verdict.verdict == .verified)
        #expect(verdict.verdict.isKnown)
    }

    @Test("a lookup without an agent, or with an empty one, sends none and carries none")
    func noAgentSendsNone() async throws {
        let origin = AgentOrigin()
        let client = client(origin, cache: nil)
        let plain = try await client.lookup(Self.address)
        let empty = try await client.lookup(Self.address, userAgent: "")
        #expect(plain.userAgent == nil)
        #expect(empty.userAgent == nil)
        #expect(await origin.paths.count == 2)
        #expect(await origin.paths.allSatisfy { !$0.contains("user_agent") })
    }

    @Test("myIP sends the agent and stays uncached")
    func myIPSendsTheAgent() async throws {
        let origin = AgentOrigin()
        let client = client(origin)
        let first = try await client.myIP(userAgent: Self.chrome)
        let second = try await client.myIP(userAgent: Self.chrome)
        #expect(first.userAgent?.agent == Self.chrome)
        #expect(second.userAgent?.agent == Self.chrome)
        #expect(await origin.rawAgents.compactMap { $0?.removingPercentEncoding } == [Self.chrome, Self.chrome])
    }

    @Test("the cache keys on the address and the agent together")
    func theCacheKeysOnThePair() async throws {
        let origin = AgentOrigin()
        let client = client(origin)
        let plain = try await client.lookup(Self.address)
        let google = try await client.lookup(Self.address, userAgent: Self.googlebot)
        let chrome = try await client.lookup(Self.address, userAgent: Self.chrome)
        let googleAgain = try await client.lookup(Self.address, userAgent: Self.googlebot)
        let plainAgain = try await client.lookup(Self.address)
        let emptyIsPlain = try await client.lookup(Self.address, userAgent: "")

        #expect(await origin.paths.count == 3, "two agents and none on one address are three requests")
        #expect(plain.userAgent == nil)
        #expect(plainAgain.userAgent == nil)
        #expect(emptyIsPlain.userAgent == nil)
        #expect(google.userAgent?.agent == Self.googlebot)
        #expect(googleAgain.userAgent?.agent == Self.googlebot)
        #expect(chrome.userAgent?.agent == Self.chrome)
    }

    @Test("concurrent misses for one address and agent share one request")
    func concurrentMissesShareOneRequestPerPair() async throws {
        let origin = AgentOrigin(delay: .milliseconds(300))
        let client = client(origin)
        let agents = try await withThrowingTaskGroup(of: String?.self) { group in
            for index in 0..<20 {
                let agent = index.isMultiple(of: 2) ? Self.googlebot : Self.chrome
                group.addTask { try await client.lookup(Self.address, userAgent: agent).userAgent?.agent }
            }
            return try await group.reduce(into: [String?]()) { $0.append($1) }
        }
        #expect(await origin.paths.count == 2)
        #expect(agents.filter { $0 == Self.googlebot }.count == 10)
        #expect(agents.filter { $0 == Self.chrome }.count == 10)
    }

    @Test("an agent longer than 1024 characters is sent whole")
    func aLongAgentIsSent() async throws {
        let origin = AgentOrigin()
        let agent = String(repeating: "Googlebot/2.1 ", count: 150)
        let result = try await client(origin).lookup(Self.address, userAgent: agent)
        #expect(await origin.rawAgents.first??.removingPercentEncoding == agent)
        #expect(result.userAgent?.agent == agent)
    }

    @Test("a bogon is answered locally and carries no verdict")
    func aBogonCarriesNone() async throws {
        let origin = AgentOrigin()
        let client = client(origin)
        let result = try await client.lookup("10.0.0.1", userAgent: Self.googlebot)
        let batch = try await client.lookupBatch(["10.0.0.1"], userAgents: ["10.0.0.1": Self.googlebot])
        #expect(result.isBogon)
        #expect(result.userAgent == nil)
        #expect(try batch["10.0.0.1"]?.get().userAgent == nil)
        #expect(await origin.paths.isEmpty)
    }

    @Test("a batch sends user_agents keyed by each address as it is sent")
    func aBatchSendsItsAgentsKeyedAsSent() async throws {
        let origin = AgentOrigin()
        let client = client(origin)
        let v6 = "2001:4860:4801:10::1"
        let results = try await client.lookupBatch(
            [Self.address, "45.83.91.2", "::ffff:45.83.91.3", v6, "45.83.91.4"],
            userAgents: [
                Self.address: Self.googlebot, "::ffff:45.83.91.3": Self.chrome, v6: "x", "45.83.91.4": "",
            ],
        )
        let bodies = await origin.batchBodies
        #expect(bodies.count == 1)
        let sent = try #require(bodies.first?["user_agents"] as? [String: String])
        #expect(sent == [Self.address: Self.googlebot, "45.83.91.3": Self.chrome, v6: "x"])
        #expect(try results[Self.address]?.get().userAgent?.agent == Self.googlebot)
        #expect(try results["::ffff:45.83.91.3"]?.get().userAgent?.agent == Self.chrome)
        #expect(try results["45.83.91.2"]?.get().userAgent == nil)
        #expect(try results["45.83.91.4"]?.get().userAgent == nil)

        // Each answer is cached on its pair: the agent's is a hit, the plain
        // lookup of the same address is not.
        let hit = try await client.lookup(Self.address, userAgent: Self.googlebot)
        #expect(hit.userAgent?.agent == Self.googlebot)
        #expect(await origin.paths.count == 1)
        _ = try await client.lookup(Self.address)
        #expect(await origin.paths.count == 2)
    }

    @Test("a batch with no agent, or only empty ones, sends no user_agents")
    func aBatchWithoutAgentsSendsNone() async throws {
        let origin = AgentOrigin()
        let client = client(origin, cache: nil)
        _ = try await client.lookupBatch([Self.address, "45.83.91.2"])
        _ = try await client.lookupBatch([Self.address, "45.83.91.2"], userAgents: [Self.address: ""])
        let bodies = await origin.batchBodies
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0["user_agents"] == nil && $0["ips"] != nil })
    }

    @Test("only a chunk holding an agent sends user_agents")
    func onlyAChunkWithAnAgentSendsThem() async throws {
        let origin = AgentOrigin()
        let ips = (0..<1001).map { "45.83.\($0 / 256).\($0 % 256)" }
        _ = try await client(origin, cache: nil).lookupBatch(
            ips, userAgents: [ips[0]: Self.googlebot], options: .init(concurrency: 1),
        )
        let bodies = await origin.batchBodies
        #expect(bodies.count == 2)
        let withAgents = bodies.filter { $0["user_agents"] != nil }
        #expect(withAgents.count == 1)
        #expect(withAgents.first?["user_agents"] as? [String: String] == [ips[0]: Self.googlebot])
    }

    @Test("a verdict the API adds reads as itself, and a malformed one is refused")
    func anUnknownVerdictIsRead() async throws {
        let added = StubTransport([Self.address: .json(Self.answer(verdict: "suspicious"))])
        let verdict = try await client(added).lookup(Self.address).userAgent?.verdict
        #expect(verdict?.rawValue == "suspicious")
        #expect(verdict?.isKnown == false)
        let broken: [[String: Any]] = [
            ["agent": "Googlebot", "verdict": "verified"], ["agent": "Googlebot", "kind": "bot", "verdict": ""],
        ]
        for verdict in broken {
            var answer = StubTransport.answer(for: Self.address)
            answer["user_agent"] = verdict
            let stub = StubTransport([Self.address: .json(answer)])
            let error = await #expect(throws: InternetDataError.self) {
                _ = try await client(stub, cache: nil, retries: 1).lookup(Self.address)
            }
            #expect(error?.kind == .serverError)
            #expect(await stub.callCount == 2)
        }
    }

    // An agent is a new overload: each call written for 3.2.0, a method reference
    // included, still compiles against the same signature.
    @Test("the calls without an agent keep their signatures")
    func theCallsWithoutAnAgentStand() {
        let client = InternetDataClient()
        let lookup: (String, Int?, Duration?) async throws -> LookupResult = client.lookup(_:retries:timeout:)
        let myIP: (Int?, Duration?) async throws -> LookupResult = client.myIP(retries:timeout:)
        let batch: ([String], InternetDataClient.BatchOptions) async throws -> BatchResults =
            client.lookupBatch(_:options:)
        _ = (lookup, myIP, batch)
    }

    static func answer(verdict: String) -> [String: Any] {
        var answer = StubTransport.answer(for: address)
        answer["user_agent"] = ["agent": "Googlebot", "kind": "bot", "verdict": verdict]
        return answer
    }

    private func client(
        _ transport: any ClientTransport, cache: CacheOptions? = CacheOptions(), retries: Int = 0,
    ) -> InternetDataClient {
        InternetDataClient(options: .init(apiKey: "key", cache: cache, retries: retries, transport: transport))
    }
}

/// An origin answering every lookup and batch, recording each request's raw path
/// and each batch body, its verdict naming the agent it received.
final class AgentOrigin: ClientTransport {
    private let delay: Duration?
    private let state = State()

    init(delay: Duration? = nil) {
        self.delay = delay
    }

    var paths: [String] {
        get async { await state.paths }
    }

    /// Each request's `user_agent` query value as it arrived, still encoded.
    var rawAgents: [String?] {
        get async {
            await state.paths.map { path in
                let query = path.split(separator: "?", maxSplits: 1).dropFirst().first ?? ""
                return query.split(separator: "&")
                    .first { $0.hasPrefix("user_agent=") }
                    .map { String($0.dropFirst("user_agent=".count)) }
            }
        }
    }

    var batchBodies: [[String: Any]] {
        get async {
            await state.bodies.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? "/"
        await state.record(path)
        if let delay {
            try await Task.sleep(for: delay)
        }
        let answer: [String: Any]
        if request.method == .post {
            let bytes = Data(try await ArraySlice(collecting: body ?? HTTPBody(), upTo: 1 << 22))
            await state.record(body: bytes)
            let decoded = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
            let agents = decoded["user_agents"] as? [String: String] ?? [:]
            var results: [String: Any] = [:]
            for ip in decoded["ips"] as? [String] ?? [] {
                results[ip] = Self.answer(ip, agents[ip])
            }
            answer = ["results": results, "errors": [String: Any]()]
        } else {
            let route = path.split(separator: "?", maxSplits: 1)
            let ip = String(route[0].dropFirst())
            let agent = URLComponents(string: "x:/?" + (route.count > 1 ? route[1] : ""))?
                .queryItems?.first { $0.name == "user_agent" }?.value
            answer = Self.answer(ip == "myip" ? "8.8.8.8" : ip, agent)
        }
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        let data = try JSONSerialization.data(withJSONObject: answer)
        return (HTTPResponse(status: .ok, headerFields: fields), HTTPBody([UInt8](data)))
    }

    private static func answer(_ ip: String, _ agent: String?) -> [String: Any] {
        var answer = StubTransport.answer(for: ip)
        if let agent {
            answer["user_agent"] = ["agent": agent, "kind": "bot", "verdict": "verified"]
        }
        return answer
    }

    private actor State {
        var paths: [String] = []
        var bodies: [Data] = []

        func record(_ path: String) {
            paths.append(path)
        }

        func record(body: Data) {
            bodies.append(body)
        }
    }
}
