import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import InternetData

/// The oauth section of the shared corpus, plus what it cannot carry: cancellation,
/// a 2xx that is not the type it claims, and the per-call timeout. Every call is
/// bounded from OUTSIDE by `settle`, because a loop in the code under test would
/// catch anything a stub threw at it.
@Suite("OAuth")
struct OauthTests {
    static let oauth = Corpus.shared.oauth
    static let baseURL = URL(string: "https://api.example.test")!
    static let deviceCodeGrant = "urn:ietf:params:oauth:grant-type:device_code"
    static let device = DeviceAuthorization(
        deviceCode: "mo_dc_x", userCode: "BCDF-GHJK", verificationURI: "https://app.example.test/device",
        expiresIn: 900, interval: 5,
    )
    /// Satisfies every operation's required members at once.
    static let everyRequiredMember = OauthStub.Reply(status: 200, body: """
        {"issuer":"https://api.example.test",
        "authorization_endpoint":"https://api.example.test/oauth/authorize",
        "token_endpoint":"https://api.example.test/oauth/token",
        "device_code":"mo_dc_x","user_code":"BCDF-GHJK",
        "verification_uri":"https://app.example.test/device","expires_in":900,"interval":1,
        "access_token":"mo_at_x","token_type":"Bearer"}
        """)

    @Test("no OAuth request carries the API key")
    func noRequestCarriesTheKey() async throws {
        let rule = try #require(Self.oauth["noCredential"])
        let key = try #require(rule["apiKey"]?.stringValue)
        let stub = OauthStub([Self.everyRequiredMember])
        let (oauth, _) = FakeClock.install(on: Self.client(stub, apiKey: key).oauth, stub)

        let id = "internetdata-cli"
        _ = try await succeed(stub) { try await oauth.metadata() }
        _ = try await succeed(stub) {
            try await oauth.deviceAuthorization(clientID: id, scope: "s", resource: "r")
        }
        _ = try await succeed(stub) { try await oauth.exchangeDeviceCode("mo_dc_x", clientID: id) }
        _ = try await succeed(stub) { try await oauth.exchangeRefreshToken("mo_rt_x", clientID: id) }
        try await succeed(stub) { try await oauth.revoke("mo_rt_x", clientID: id) }
        _ = try await succeed(stub) { try await oauth.pollDeviceToken(Self.device, clientID: id) }

        let sent = stub.requests
        #expect(sent.count == 6)
        let headers = Set((rule["forbiddenHeaders"]?.arrayValue ?? []).compactMap(\.stringValue))
        let query = Set((rule["forbiddenQuery"]?.arrayValue ?? []).compactMap(\.stringValue))
        #expect(!headers.isEmpty && !query.isEmpty)
        for request in sent {
            for field in request.headers {
                #expect(!headers.contains(field.name.canonicalName), "\(request.path) carried \(field.name)")
                #expect(!field.value.contains(key), "\(request.path): the key rode \(field.name)")
            }
            #expect(query.isDisjoint(with: request.queryKeys), "\(request.path) carried the key's query name")
            #expect(!request.url.contains(key), "\(request.path): the key is in the URL")
            #expect(!request.body.contains(key), "\(request.path): the key is in the body")
        }
    }

    // Keyless, so the forms prove a client needs no key for any of this.
    @Test("each operation requests its endpoint with exactly its form fields")
    func formsAndEndpoints() async throws {
        let endpoints = try #require(Self.oauth["endpoints"])
        let forms = try #require(Self.oauth["forms"])
        let contentType = try #require(forms["contentType"]?.stringValue)
        for testCase in forms["cases"]?.arrayValue ?? [] {
            let name = testCase["name"]?.stringValue ?? "?"
            let stub = OauthStub([Self.everyRequiredMember])
            let oauth = Self.client(stub).oauth
            let operation = try #require(testCase["operation"]?.stringValue)
            let args = try #require(testCase["args"])

            try await succeed(stub) { try await Self.call(oauth, operation, args) }

            let sent = stub.requests
            try #require(sent.count == 1, "\(name): sent \(sent.count) requests")
            let endpoint = try #require(endpoints[testCase["endpoint"]?.stringValue ?? ""])
            #expect(sent[0].endpoint == Self.endpoint(endpoint), "\(name)")
            let sentType = sent[0].contentType ?? "none"
            #expect(sent[0].contentType?.hasPrefix(contentType) == true, "\(name): \(sentType)")
            let want = (testCase["fields"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            #expect(try formFields(sent[0].body) == want, "\(name)")
        }

        let stub = OauthStub([Self.everyRequiredMember])
        let oauth = Self.client(stub).oauth
        _ = try await succeed(stub) { try await oauth.metadata() }
        #expect(stub.requests.map(\.endpoint) == [Self.endpoint(try #require(endpoints["metadata"]))])
    }

    @Test("a 2xx decodes on presence: absent stays absent, an empty scope stays present")
    func responsesDecode() async throws {
        let responses = try #require(Self.oauth["responses"])
        let operations: [(String, @Sendable (OauthAPI) async throws -> [String: JSONValue], Set<String>)] = [
            ("metadata", { try await $0.metadata().wireFields }, OauthMetadata.wireNames),
            ("deviceAuthorization", {
                try await $0.deviceAuthorization(clientID: "internetdata-cli").wireFields
            }, DeviceAuthorization.wireNames),
            ("token", {
                try await $0.exchangeDeviceCode("mo_dc_x", clientID: "internetdata-cli").wireFields
            }, TokenResponse.wireNames),
        ]
        for (section, call, names) in operations {
            for testCase in responses[section]?.arrayValue ?? [] {
                let label = "\(section)/\(testCase["name"]?.stringValue ?? "?")"
                let stub = OauthStub([.init(testCase)])
                let oauth = Self.client(stub).oauth

                let fields = try await succeed(stub) { try await call(oauth) }

                for (member, value) in testCase["expect"]?["present"]?.objectValue ?? [:] {
                    #expect(names.contains(member), "\(label): no member maps \(member)")
                    #expect(fields[member] == value, "\(label): \(member)")
                }
                for member in (testCase["expect"]?["absent"]?.arrayValue ?? []).compactMap(\.stringValue) {
                    #expect(names.contains(member), "\(label): no member maps \(member)")
                    #expect(fields[member] == nil, "\(label): \(member) must be absent")
                }
            }
        }
        for testCase in responses["revoke"]?.arrayValue ?? [] {
            let stub = OauthStub([.init(testCase)])
            let oauth = Self.client(stub).oauth

            try await succeed(stub) { try await oauth.revoke("mo_rt_x", clientID: "c") }

            #expect(stub.requests.count == 1)
        }
    }

    @Test(
        "a 2xx that is not a token is the ordinary error, and is not retried",
        arguments: [
            #"{"token_type":"Bearer","expires_in":3600}"#,
            #"{"access_token":"mo_at_x","token_type":"Bearer","expires_in":"3600"}"#,
            #"{"access_token":null,"token_type":"Bearer","expires_in":3600}"#,
            "<html>",
        ],
    )
    func malformedTokenIsTheOrdinaryError(_ body: String) async throws {
        let stub = OauthStub([.init(status: 200, body: body)])
        let oauth = Self.client(stub).oauth

        let outcome = try #require(await settle(stub) {
            try await oauth.exchangeDeviceCode("mo_dc_x", clientID: "internetdata-cli")
        })

        #expect(stub.requests.count == 1)
        guard case .failure(let error as InternetDataError) = outcome else {
            Issue.record("settled with \(outcome), want a InternetDataError")
            return
        }
        #expect(error.kind == .serverError)
        #expect(error.status == 200)
    }

    // No corpus case: every response there decodes. One member left out per case,
    // since a body missing two at once let a defaulting decoder survive elsewhere.
    @Test(
        "an answer missing any one required member is the ordinary error",
        arguments: [
            ("metadata", "issuer"), ("metadata", "authorization_endpoint"), ("metadata", "token_endpoint"),
            ("deviceAuthorization", "device_code"), ("deviceAuthorization", "user_code"),
            ("deviceAuthorization", "verification_uri"), ("deviceAuthorization", "expires_in"),
            ("deviceAuthorization", "interval"), ("exchangeDeviceCode", "access_token"),
            ("exchangeDeviceCode", "token_type"), ("exchangeDeviceCode", "expires_in"),
        ],
    )
    func missingARequiredMemberIsTheOrdinaryError(_ operation: String, _ member: String) async throws {
        let args = JSONValue.object([
            "clientId": .string("internetdata-cli"), "deviceCode": .string("mo_dc_x"),
        ])
        let whole = OauthStub([Self.everyRequiredMember])
        let decodes = Self.client(whole, retries: 0).oauth
        try await succeed(whole) { try await Self.call(decodes, operation, args) }

        var members = try JSONDecoder().decode(
            [String: JSONValue].self, from: Data(Self.everyRequiredMember.body.utf8),
        )
        try #require(members.removeValue(forKey: member) != nil, "\(member) is not in the body")
        let body = String(decoding: try JSONEncoder().encode(members), as: UTF8.self)
        let stub = OauthStub([.init(status: 200, body: body)])
        let oauth = Self.client(stub, retries: 0).oauth

        let outcome = try #require(await settle(stub) { try await Self.call(oauth, operation, args) })

        #expect(stub.requests.count == 1)
        guard case .failure(let error as InternetDataError) = outcome else {
            Issue.record("settled with \(outcome), want an InternetDataError")
            return
        }
        #expect(error.kind == .serverError)
        #expect(error.status == 200)
    }

    @Test("a failed answer is an OAuth refusal only when it is one")
    func errorsAreClassified() async throws {
        for testCase in Self.oauth["errors"]?["cases"]?.arrayValue ?? [] {
            let stub = OauthStub([.init(testCase)])
            let oauth = Self.client(stub).oauth

            let outcome = await settle(stub) {
                try await oauth.exchangeDeviceCode("mo_dc_x", clientID: "internetdata-cli")
            }

            let expect = try #require(testCase["expect"])
            assertOutcome(outcome, expect, type: expect["type"]?.stringValue, testCase["name"]?.stringValue)
        }
    }

    @Test("only what consumes nothing is retried, and never an OAuth refusal")
    func retries() async throws {
        for testCase in Self.oauth["retries"]?["cases"]?.arrayValue ?? [] {
            let name = testCase["name"]?.stringValue ?? "?"
            let stub = OauthStub((testCase["responses"]?.arrayValue ?? []).map(OauthStub.Reply.init))
            let oauth = Self.client(stub).oauth
            let operation = try #require(testCase["operation"]?.stringValue)
            let args = try #require(testCase["args"])

            let outcome = await settle(stub) { try await Self.call(oauth, operation, args) }

            let expect = try #require(testCase["expect"])
            #expect(stub.requests.count == expect["requests"]?.intValue, "\(name): requests sent")
            guard expect["outcome"]?.stringValue != "ok" else {
                if case .failure(let error) = outcome {
                    Issue.record("\(name): failed with \(error)")
                }
                continue
            }
            assertOutcome(outcome, expect, type: expect["outcome"]?.stringValue, name)
        }
    }

    // Waits are asserted exactly, through the seam that replaces the sleep AND the
    // clock together, so the deadline reads the same time the waits spent.
    @Test("pollDeviceToken waits, widens and ends as the corpus says")
    func poll() async throws {
        let tokenEndpoint = Self.endpoint(try #require(Self.oauth["endpoints"]?["token"]))
        for testCase in Self.oauth["poll"]?["cases"]?.arrayValue ?? [] {
            let name = testCase["name"]?.stringValue ?? "?"
            let stub = OauthStub((testCase["responses"]?.arrayValue ?? []).map(OauthStub.Reply.init))
            let (oauth, clock) = FakeClock.install(on: Self.client(stub).oauth, stub)
            let clientID = try #require(testCase["clientId"]?.stringValue)
            let device = try JSONDecoder().decode(
                DeviceAuthorization.self, from: try #require(testCase["device"]).encoded,
            )

            let outcome = await settle(stub) { try await oauth.pollDeviceToken(device, clientID: clientID) }

            let expect = try #require(testCase["expect"])
            #expect(clock.waits == (expect["waits"]?.arrayValue ?? []).compactMap(\.doubleValue), "\(name)")
            #expect(stub.requests.count == expect["requests"]?.intValue, "\(name): requests sent")
            let form = [
                "grant_type": Self.deviceCodeGrant, "device_code": device.deviceCode, "client_id": clientID,
            ]
            for request in stub.requests {
                #expect(request.endpoint == tokenEndpoint, "\(name)")
                #expect(try formFields(request.body) == form, "\(name)")
            }
            guard expect["outcome"]?.stringValue != "token" else {
                let token = try #require(outcome, "\(name)").get()
                if let want = expect["token"]?["access_token"]?.stringValue {
                    #expect(token.accessToken == want, "\(name)")
                }
                continue
            }
            assertOutcome(outcome, expect, type: expect["outcome"]?.stringValue, name)
        }
    }

    // No corpus case: cancelling has to stop the real wait before the first request.
    @Test("cancelling a poll during its first wait settles at once")
    func cancellingAPollStopsItsWait() async throws {
        let stub = OauthStub([.init(status: 400, body: #"{"error":"authorization_pending"}"#)], limit: 1)
        let oauth = Self.client(stub).oauth

        let started = ContinuousClock.now
        let call = Task { try await oauth.pollDeviceToken(Self.device, clientID: "internetdata-cli") }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()
        let outcome = await settle(stub, within: .seconds(3)) { try await call.value }

        guard case .failure(let error)? = outcome, error is CancellationError else {
            Issue.record("settled with \(String(describing: outcome)), want CancellationError")
            return
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(stub.requests.isEmpty)
    }

    enum Operation: String, CaseIterable, Sendable {
        case metadata, deviceAuthorization, exchangeDeviceCode, exchangeRefreshToken, revoke, pollDeviceToken
    }

    // Against a body that stalls after its head, so the bound is shown to cover the
    // body. Revoke reads no body, so its origin never answers at all.
    @Test("a per-call timeout below the client's bounds every OAuth request", arguments: Operation.allCases)
    func perCallTimeout(_ operation: Operation) async throws {
        let origin = try await TestOrigin.start { _ in operation == .revoke ? .silence : .stalledJSON }
        defer { Task { try? await origin.stop() } }
        let stub = OauthStub([])
        let client = InternetDataClient(
            options: .init(baseURL: URL(string: "http://127.0.0.1:\(origin.port)")!, retries: 0),
        )
        let (oauth, _) = FakeClock.install(on: client.oauth, stub)
        let timeout = TimeoutTests.timeout

        let started = ContinuousClock.now
        let outcome = await settle(stub) { () async throws -> Void in
            switch operation {
            case .metadata:
                _ = try await oauth.metadata(timeout: timeout)
            case .deviceAuthorization:
                _ = try await oauth.deviceAuthorization(clientID: "c", timeout: timeout)
            case .exchangeDeviceCode:
                _ = try await oauth.exchangeDeviceCode("d", clientID: "c", timeout: timeout)
            case .exchangeRefreshToken:
                _ = try await oauth.exchangeRefreshToken("r", clientID: "c", timeout: timeout)
            case .revoke:
                try await oauth.revoke("r", clientID: "c", timeout: timeout)
            case .pollDeviceToken:
                _ = try await oauth.pollDeviceToken(Self.device, clientID: "c", timeout: timeout)
            }
        }
        let elapsed = ContinuousClock.now - started

        guard case .failure(let error as InternetDataError)? = outcome else {
            Issue.record("settled with \(String(describing: outcome)), want a timeout")
            return
        }
        #expect(error.kind == .network)
        #expect(error.message.hasPrefix("the request timed out"), "\(error.message)")
        #expect(elapsed >= TimeoutTests.atLeast, "failed after \(elapsed), before the deadline could fire")
        #expect(origin.receivedPaths.count == 1)
    }

    // OauthAPI sends straight to the transport rather than through the generated
    // client, so it is a second place a doubled slash can come from.
    @Test("a trailing slash on the base URL is dropped from OAuth requests", arguments: ["/", "//", "///"])
    func aTrailingSlashIsDroppedFromOauth(_ suffix: String) async throws {
        let origin = try await TestOrigin.start { _ in .json(Self.everyRequiredMember.body) }
        defer { Task { try? await origin.stop() } }
        let client = InternetDataClient(
            options: .init(
                baseURL: URL(string: "http://127.0.0.1:\(origin.port)\(suffix)")!, retries: 0,
            ),
        )

        _ = try await client.oauth.metadata()

        #expect(origin.receivedPaths == ["/.well-known/oauth-authorization-server"])
    }

    @Test("every operation refuses an impossible timeout", arguments: Operation.allCases)
    func everyOperationRefusesAnImpossibleTimeout(_ operation: Operation) async throws {
        // One reply on offer, so a request that leaked past the check is recorded
        // and fails the last expectation: a stub with none trips instead of
        // recording, and `requests` would stay empty whatever happened.
        let stub = OauthStub([Self.everyRequiredMember])
        let (oauth, _) = FakeClock.install(on: Self.client(stub).oauth, stub)

        let outcome = await settle(stub) { () async throws -> Void in
            switch operation {
            case .metadata:
                _ = try await oauth.metadata(timeout: .zero)
            case .deviceAuthorization:
                _ = try await oauth.deviceAuthorization(clientID: "c", timeout: .zero)
            case .exchangeDeviceCode:
                _ = try await oauth.exchangeDeviceCode("d", clientID: "c", timeout: .zero)
            case .exchangeRefreshToken:
                _ = try await oauth.exchangeRefreshToken("r", clientID: "c", timeout: .zero)
            case .revoke:
                try await oauth.revoke("r", clientID: "c", timeout: .zero)
            case .pollDeviceToken:
                _ = try await oauth.pollDeviceToken(Self.device, clientID: "c", timeout: .zero)
            }
        }

        guard case .failure(let error as InternetDataError)? = outcome else {
            Issue.record("settled with \(String(describing: outcome)), want a InternetDataError")
            return
        }
        #expect(error.kind == .badRequest)
        #expect(stub.requests.isEmpty)
    }

    @Test("the client's own timeout bounds an OAuth request")
    func clientTimeout() async throws {
        let origin = try await TestOrigin.start { _ in .stalledJSON }
        defer { Task { try? await origin.stop() } }
        let stub = OauthStub([])
        let oauth = InternetDataClient(
            options: .init(
                baseURL: URL(string: "http://127.0.0.1:\(origin.port)")!, retries: 0,
                timeout: .milliseconds(300),
            ),
        ).oauth

        let outcome = await settle(stub) { try await oauth.exchangeDeviceCode("d", clientID: "c") }

        guard case .failure(let error as InternetDataError)? = outcome else {
            Issue.record("settled with \(String(describing: outcome)), want a timeout")
            return
        }
        #expect(error.kind == .network)
    }

    static func client(_ stub: OauthStub, apiKey: String? = nil, retries: Int = 2) -> InternetDataClient {
        InternetDataClient(
            options: .init(apiKey: apiKey, baseURL: baseURL, retries: retries, transport: stub),
        )
    }

    static func endpoint(_ endpoint: JSONValue) -> String {
        "\(endpoint["method"]?.stringValue ?? "?") \(endpoint["path"]?.stringValue ?? "?")"
    }

    @discardableResult
    static func call(_ oauth: OauthAPI, _ operation: String, _ args: JSONValue) async throws -> String {
        let clientID = args["clientId"]?.stringValue ?? ""
        switch operation {
        case "metadata":
            return try await oauth.metadata().issuer
        case "deviceAuthorization":
            let scope = args["scope"]?.stringValue
            return try await oauth.deviceAuthorization(
                clientID: clientID, scope: scope, resource: args["resource"]?.stringValue,
            ).deviceCode
        case "exchangeDeviceCode":
            let code = args["deviceCode"]?.stringValue ?? ""
            return try await oauth.exchangeDeviceCode(code, clientID: clientID).accessToken
        case "exchangeRefreshToken":
            let token = args["refreshToken"]?.stringValue ?? ""
            return try await oauth.exchangeRefreshToken(token, clientID: clientID).accessToken
        case "revoke":
            try await oauth.revoke(args["token"]?.stringValue ?? "", clientID: clientID)
            return ""
        default:
            throw InternetDataError(kind: .badRequest, message: "an operation this suite lacks: \(operation)")
        }
    }
}

/// `type` is oauth (``OauthError/rejected(_:)``), accessDenied, expiredToken, or
/// client: the ordinary ``InternetDataError``. Swift's OAuth error carries no
/// kind, so kind and retryable are asserted on the ordinary error only.
func assertOutcome<T>(_ outcome: Result<T, any Error>?, _ want: JSONValue, type: String?, _ label: String?) {
    let label = label ?? "?"
    guard case .failure(let error)? = outcome else {
        Issue.record("\(label): settled with \(String(describing: outcome)), want \(type ?? "?")")
        return
    }
    if type == "client" {
        guard let ordinary = error as? InternetDataError else {
            Issue.record("\(label): threw \(error), want a InternetDataError")
            return
        }
        want["kind"]?.stringValue.map { #expect(ordinary.kind.rawValue == $0, "\(label): kind") }
        want["retryable"]?.boolValue.map { #expect(ordinary.isRetryable == $0, "\(label): retryable") }
        want["status"]?.intValue.map { #expect(ordinary.status == $0, "\(label): status") }
        return
    }
    let response: OauthErrorResponse
    switch (type, error as? OauthError) {
    case ("oauth", .rejected(let refusal)?), ("accessDenied", .accessDenied(let refusal)?),
        ("expiredToken", .expiredToken(let refusal)?):
        response = refusal
    default:
        Issue.record("\(label): threw \(error), want \(type ?? "?")")
        return
    }
    want["errorCode"]?.stringValue.map { #expect(response.errorCode == $0, "\(label): errorCode") }
    if let description = want["errorDescription"] {
        #expect(response.errorDescription == description.stringValue, "\(label): errorDescription")
    }
    if let status = want["status"] {
        #expect(response.status == status.intValue, "\(label): status")
    }
}

/// Decoded the way a server decodes a form: `+` is a space.
func formFields(_ body: String) throws -> [String: String] {
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let decode = { (text: Substring) in
            text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(text)
        }
        let name = decode(parts[0])
        try #require(fields[name] == nil, "\(name) sent twice")
        fields[name] = parts.count > 1 ? decode(parts[1]) : ""
    }
    return fields
}

/// The call's value, failing the test if it threw or never settled.
@discardableResult
func succeed<T: Sendable>(
    _ stub: OauthStub, _ call: @escaping @Sendable () async throws -> T,
) async throws -> T {
    try #require(await settle(stub, call)).get()
}

/// The call's outcome, or `nil` if it has not settled within `limit`. Either that
/// or a tripped stub fails the test from here: the code under test catches what
/// a stub throws, so only a race it cannot see can end a loop.
func settle<T: Sendable>(
    _ stub: OauthStub, within limit: Duration = .seconds(10),
    _ call: @escaping @Sendable () async throws -> T,
) async -> Result<T, any Error>? {
    let settled = Settled<T>()
    Task {
        do {
            settled.resolve(.success(try await call()))
        } catch {
            settled.resolve(.failure(error))
        }
    }
    let timer = Task {
        try? await Task.sleep(for: limit)
        settled.resolve(nil)
    }
    let outcome = await settled.value
    timer.cancel()
    if let reason = stub.tripReason {
        Issue.record("\(reason): the call under test does not end")
    }
    if outcome == nil {
        Issue.record("the call did not settle within \(limit)")
    }
    return outcome
}

private final class Settled<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<T, any Error>??
    private var waiter: CheckedContinuation<Result<T, any Error>?, Never>?

    var value: Result<T, any Error>? {
        get async {
            await withCheckedContinuation { continuation in
                let decided: Result<T, any Error>?? = lock.withLock {
                    if outcome == nil {
                        waiter = continuation
                    }
                    return outcome
                }
                if let decided {
                    continuation.resume(returning: decided)
                }
            }
        }
    }

    func resolve(_ result: Result<T, any Error>?) {
        let waiting: CheckedContinuation<Result<T, any Error>?, Never>? = lock.withLock {
            guard outcome == nil else {
                return nil
            }
            outcome = .some(result)
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: result)
    }
}

/// Replaces a poll's wait and clock together. Past the bound the wait never
/// returns and the clock reads far past any deadline, so a loop that does not end
/// fails its test instead of spinning.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    private var elapsed: Duration = .zero
    private var reads = 0

    var waits: [Double] { lock.withLock { recorded } }

    static func install(on api: OauthAPI, _ stub: OauthStub) -> (OauthAPI, FakeClock) {
        let clock = FakeClock()
        let start = ContinuousClock.now
        var api = api
        api.sleep = { wait in
            guard clock.wait(wait) else {
                await stub.trip("waited \(OauthStub.loopBound) times")
            }
        }
        api.now = { start + (clock.read() ?? .seconds(365 * 24 * 3600)) }
        return (api, clock)
    }

    private func wait(_ duration: Duration) -> Bool {
        lock.withLock {
            guard recorded.count < OauthStub.loopBound else {
                return false
            }
            let (seconds, attoseconds) = duration.components
            recorded.append(Double(seconds) + Double(attoseconds) / 1e18)
            elapsed += duration
            return true
        }
    }

    private func read() -> Duration? {
        lock.withLock {
            reads += 1
            return reads > OauthStub.loopBound ? nil : elapsed
        }
    }
}

/// Answers in order, repeating the last reply, and records what left the client.
/// Past its bound it never answers at all.
final class OauthStub: ClientTransport, @unchecked Sendable {
    static let loopBound = 16

    struct Reply: Sendable {
        var status: Int
        var body: String

        init(status: Int, body: String) {
            self.status = status
            self.body = body
        }

        /// A corpus response: `rawBody` sent verbatim, `body` as JSON.
        init(_ fixture: JSONValue) {
            status = fixture["status"]?.intValue ?? 0
            body = fixture["rawBody"]?.stringValue
                ?? fixture["body"].map { String(decoding: $0.encoded, as: UTF8.self) } ?? ""
        }
    }

    struct Sent: Sendable {
        let method: String
        let path: String
        let url: String
        let headers: HTTPFields
        let body: String

        var endpoint: String {
            "\(method) \(path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path)"
        }

        var contentType: String? { headers[.contentType] }

        var queryKeys: Set<String> {
            guard let query = path.split(separator: "?", maxSplits: 1).dropFirst().first else {
                return []
            }
            return Set(query.split(separator: "&").map {
                String($0.split(separator: "=", maxSplits: 1)[0]).lowercased()
            })
        }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private let limit: Int
    private var sent: [Sent] = []
    private var tripped: String?

    init(_ replies: [Reply], limit: Int = OauthStub.loopBound) {
        self.replies = replies
        self.limit = limit
    }

    var requests: [Sent] { lock.withLock { sent } }
    var tripReason: String? { lock.withLock { tripped } }

    func trip(_ reason: String) async -> Never {
        lock.withLock {
            tripped = tripped ?? reason
        }
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        fatalError("a continuation nobody holds resumed")
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let bytes = try await ArraySlice(collecting: body ?? HTTPBody(), upTo: 1 << 20)
        let reply: Reply? = lock.withLock {
            guard sent.count < limit, !replies.isEmpty else {
                return nil
            }
            let path = request.path ?? ""
            sent.append(Sent(
                method: request.method.rawValue, path: path, url: baseURL.absoluteString + path,
                headers: request.headerFields, body: String(decoding: bytes, as: UTF8.self),
            ))
            defer {
                if replies.count > 1 {
                    replies.removeFirst()
                }
            }
            return replies[0]
        }
        guard let reply else {
            await trip("sent more than \(limit) request(s)")
        }
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        return (HTTPResponse(status: .init(code: reply.status), headerFields: fields), HTTPBody(reply.body))
    }
}

extension OauthMetadata {
    static let wireNames: Set<String> = [
        "issuer", "authorization_endpoint", "token_endpoint", "device_authorization_endpoint",
        "revocation_endpoint", "scopes_supported", "response_types_supported", "grant_types_supported",
        "code_challenge_methods_supported", "token_endpoint_auth_methods_supported",
        "authorization_response_iss_parameter_supported", "service_documentation",
    ]

    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "issuer": .string(issuer), "authorization_endpoint": .string(authorizationEndpoint),
            "token_endpoint": .string(tokenEndpoint),
        ]
        deviceAuthorizationEndpoint.map { fields["device_authorization_endpoint"] = .string($0) }
        revocationEndpoint.map { fields["revocation_endpoint"] = .string($0) }
        scopesSupported.map { fields["scopes_supported"] = .array($0.map(JSONValue.string)) }
        responseTypesSupported.map { fields["response_types_supported"] = .array($0.map(JSONValue.string)) }
        grantTypesSupported.map { fields["grant_types_supported"] = .array($0.map(JSONValue.string)) }
        codeChallengeMethodsSupported.map {
            fields["code_challenge_methods_supported"] = .array($0.map(JSONValue.string))
        }
        tokenEndpointAuthMethodsSupported.map {
            fields["token_endpoint_auth_methods_supported"] = .array($0.map(JSONValue.string))
        }
        authorizationResponseIssParameterSupported.map {
            fields["authorization_response_iss_parameter_supported"] = .bool($0)
        }
        serviceDocumentation.map { fields["service_documentation"] = .string($0) }
        return fields
    }
}

extension DeviceAuthorization {
    static let wireNames: Set<String> = [
        "device_code", "user_code", "verification_uri", "verification_uri_complete", "expires_in", "interval",
    ]

    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "device_code": .string(deviceCode), "user_code": .string(userCode),
            "verification_uri": .string(verificationURI), "expires_in": .int(expiresIn),
            "interval": .int(interval),
        ]
        verificationURIComplete.map { fields["verification_uri_complete"] = .string($0) }
        return fields
    }
}

extension TokenResponse {
    static let wireNames: Set<String> = [
        "access_token", "token_type", "expires_in", "refresh_token", "scope", "apikey_id", "apikey",
    ]

    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "access_token": .string(accessToken), "token_type": .string(tokenType),
            "expires_in": .int(expiresIn),
        ]
        refreshToken.map { fields["refresh_token"] = .string($0) }
        scope.map { fields["scope"] = .string($0) }
        apikeyID.map { fields["apikey_id"] = .string($0) }
        apikey.map { fields["apikey"] = .string($0) }
        return fields
    }
}
