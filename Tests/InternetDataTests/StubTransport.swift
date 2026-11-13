import Foundation
import HTTPTypes
import OpenAPIRuntime

@testable import InternetData

/// A transport that answers from a table and records what it was asked for, so
/// "the key was on the wire", "never touched the network" and "kept at most N
/// in flight" are asserted rather than assumed.
///
/// A lookup is keyed by its target (`1.1.1.1`, `asn/9009`, `myip`), a database
/// call by its path, and a `POST /batch` is answered from the addresses it
/// carries.
final class StubTransport: ClientTransport {
    struct Route: Sendable {
        var status: Int = 200
        var body: Data?
        var headers: [String: String] = [:]

        static func json(_ object: [String: Any], status: Int = 200) -> Route {
            Route(status: status, body: try? JSONSerialization.data(withJSONObject: object))
        }
    }

    private let routes: [String: Route]
    private let delay: Duration?
    private let state = State()

    init(_ routes: [String: Route] = [:], delay: Duration? = nil) {
        self.routes = routes
        self.delay = delay
    }

    /// Successful lookups for a set of addresses, which is what most cases want.
    static func answering(_ ips: String...) -> StubTransport {
        StubTransport(answers(for: ips))
    }

    static func answers(for ips: [String]) -> [String: Route] {
        Dictionary(uniqueKeysWithValues: ips.map { ($0, Route(body: Data(answerJSON(for: $0).utf8))) })
    }

    /// Every address refused as one the API holds nothing for: what a test that
    /// counts requests wants, since reading a refusal costs next to nothing and
    /// thousands of whole answers starved the timing tests beside them.
    static func refusals(for ips: [String]) -> [String: Route] {
        let refusal = Route.json(["error": "not found"], status: 404)
        return Dictionary(uniqueKeysWithValues: ips.map { ($0, refusal) })
    }

    /// ``answer(for:)`` as the bytes a server sends, serialized once and filled in
    /// per address: a batch test asks for thousands, and serializing each one
    /// starved the timing tests running beside it on a small CI runner.
    static func answerJSON(for ip: String) -> String {
        answerTemplate.replacingOccurrences(of: "\"\(placeholder)\"", with: quoted(ip))
    }

    private static let placeholder = "address-placeholder"

    private static let answerTemplate = String(
        decoding: (try? JSONSerialization.data(withJSONObject: answer(for: placeholder))) ?? Data(), as: UTF8.self,
    )

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The smallest whole answer the API gives: Unlimited's, every member the
    /// spec requires and nothing else.
    static func answer(for ip: String) -> [String: Any] {
        [
            "ip": ip, "is_bogon": false, "is_tor": false, "is_relay": false, "is_anycast": false,
            "is_carrier": false, "is_satellite": false, "is_ssh": false, "is_smtp": false,
            "is_web": false, "is_dns_resolver": false, "is_bittorrent": false,
            "tor": [String: Any](), "relay": [String: Any](),
            "location": [
                "continent": "EU", "continent_name": "Europe", "country": "AT",
                "country_name": "Austria", "timezone": "Europe/Vienna", "currency_code": "EUR",
                "currency_name": "Euro", "currency_symbol": "€", "flag_emoji": "", "flag_unicode": "",
            ],
            "asn": [
                "asn": 9009, "name": "M247 Europe SRL", "domain": "m247global.com", "type": "hosting",
                "prefix": "146.70.116.0/24",
            ],
            "company": ["name": "", "domain": ""],
            "hostname": "",
            "abuse": ["email": ""],
        ]
    }

    var callCount: Int {
        get async { await state.calls.count }
    }

    var calls: [String] {
        get async { await state.calls }
    }

    /// Every request's path with its query, in arrival order.
    var targets: [String] {
        get async { await state.targets }
    }

    /// Every address a `POST /batch` carried, as sent, in the order the requests
    /// arrived.
    var batchIps: [String] {
        get async { await state.batchIps }
    }

    var peakInFlight: Int {
        get async { await state.peak }
    }

    /// The members each `POST /batch` body carried, sorted.
    var batchMembers: [[String]] {
        get async { await state.batchMembers }
    }

    /// The `Authorization` header of every request, so "the key was presented"
    /// is asserted at the wire rather than inferred from the option.
    var authorizations: [String?] {
        get async { await state.authorizations }
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let key = Self.key(for: request)
        await state.enter(key, target: request.path ?? "/", authorization: request.headerFields[.authorization])
        do {
            if let delay {
                try await Task.sleep(for: delay)
            }
        } catch {
            await state.leave()
            throw error
        }

        // A batch is answered from the addresses in its body rather than from
        // the path, unless a route for "batch" itself is served as it is, for a
        // body the API would never build. An unrouted lookup answers the way the
        // API answers a target it cannot read, and an unrouted database path the
        // way it answers an unknown ID, so a case can exercise either without a
        // second stub.
        let route: Route
        if request.method == .post, key == "batch" {
            if let raw = routes["batch"] {
                route = raw
            } else {
                route = try await batchRoute(body)
            }
        } else if let routed = routes[key] {
            route = routed
        } else if key.hasPrefix("/api/") {
            route = .json(["rc": "UNKNOWN_DATASET"], status: 404)
        } else {
            route = .json(["error": "not a valid IP address, AS number or domain"], status: 400)
        }
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        for (name, value) in route.headers {
            guard let field = HTTPField.Name(name) else {
                continue
            }
            fields[field] = value
        }
        let response = HTTPResponse(status: .init(code: route.status), headerFields: fields)
        await state.leave()
        return (response, route.body.map { HTTPBody([UInt8]($0)) })
    }

    // A POST /batch is answered the way the API answers one: every address the
    // table knows is a result if its route is a 200 and an entry error otherwise,
    // and an unknown address is the 400 the API gives a string that is not one.
    // One call however many addresses, which is what the request counts measure.
    // Each answer goes in as the bytes it was routed with, never parsed again.
    private func batchRoute(_ body: HTTPBody?) async throws -> Route {
        let bytes = try await ArraySlice(collecting: body ?? HTTPBody(), upTo: 1 << 20)
        let decoded = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
        let ips = decoded?["ips"] as? [String] ?? []
        await state.sent(ips, members: (decoded?.keys).map { $0.sorted() } ?? [])
        var results: [String] = []
        var failures: [String] = []
        var messages: [Data: String] = [:]
        for ip in ips {
            guard let route = routes[ip] else {
                let refusal = #"{"status":400,"error":"not a valid IP address, AS number or domain"}"#
                failures.append(Self.quoted(ip) + ":" + refusal)
                continue
            }
            if route.status == 200 {
                let served = String(decoding: route.body ?? Data("{}".utf8), as: UTF8.self)
                results.append(Self.quoted(ip) + ":" + served)
                continue
            }
            let served = route.body ?? Data()
            let message = messages[served] ?? {
                let answer = try? JSONSerialization.jsonObject(with: served) as? [String: Any]
                return answer?["error"] as? String ?? "request failed"
            }()
            messages[served] = message
            failures.append(Self.quoted(ip) + #":{"status":\#(route.status),"error":\#(Self.quoted(message))}"#)
        }
        let answer = #"{"results":{"# + results.joined(separator: ",") + #"},"errors":{"#
            + failures.joined(separator: ",") + "}}"
        return Route(body: Data(answer.utf8))
    }

    // A lookup's path is its target; anything under /api/ is keyed by its path so
    // the database endpoints can be routed too.
    private static func key(for request: HTTPRequest) -> String {
        let path = (request.path ?? "/").split(separator: "?", maxSplits: 1)[0]
        if path.hasPrefix("/api/") {
            return String(path)
        }
        let trimmed = String(path.dropFirst())
        return trimmed.removingPercentEncoding ?? trimmed
    }

    private actor State {
        var calls: [String] = []
        var targets: [String] = []
        var authorizations: [String?] = []
        var batchIps: [String] = []
        var batchMembers: [[String]] = []
        var peak = 0
        private var inFlight = 0

        func sent(_ ips: [String], members: [String]) {
            batchIps += ips
            batchMembers.append(members)
        }

        func enter(_ key: String, target: String, authorization: String?) {
            calls.append(key)
            targets.append(target)
            authorizations.append(authorization)
            inFlight += 1
            peak = max(peak, inFlight)
        }

        func leave() {
            inFlight -= 1
        }
    }
}

extension StubTransport {
    static let listPath = "/api/v2/database/list"
    static let metadataPath = "/api/v2/database/metadata"
    static let checksumPath = "/api/v2/database/checksum"
    static let downloadsPath = "/api/v2/database/downloads"
    static let downloadPath = "/api/v2/database/download"
    static let entitlementPath = "/api/v1/entitlement"
}
