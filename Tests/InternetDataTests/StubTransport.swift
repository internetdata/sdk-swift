import Foundation
import HTTPTypes
import OpenAPIRuntime

@testable import InternetData

/// A transport that answers from a table keyed by path, and records what it was
/// asked for, so "the key was on the wire" and "no second request was issued"
/// are asserted rather than assumed.
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

    var callCount: Int {
        get async { await state.calls.count }
    }

    var calls: [String] {
        get async { await state.calls }
    }

    /// The `Authorization` header of every request, so "the key was presented"
    /// is asserted at the wire rather than inferred from the option.
    var authorizations: [String?] {
        get async { await state.authorizations }
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = String((request.path ?? "/").split(separator: "?", maxSplits: 1)[0])
        await state.record(path, authorization: request.headerFields[.authorization])
        if let delay {
            try await Task.sleep(for: delay)
        }

        // An unrouted path answers the way the API does, so a case can exercise
        // an unknown id without a second stub.
        let route = routes[path] ?? .json(["rc": "UNKNOWN_DATASET"], status: 404)
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        for (name, value) in route.headers {
            guard let field = HTTPField.Name(name) else {
                continue
            }
            fields[field] = value
        }
        let response = HTTPResponse(status: .init(code: route.status), headerFields: fields)
        return (response, route.body.map { HTTPBody([UInt8]($0)) })
    }

    private actor State {
        var calls: [String] = []
        var authorizations: [String?] = []

        func record(_ path: String, authorization: String?) {
            calls.append(path)
            authorizations.append(authorization)
        }
    }
}

extension StubTransport {
    static let listPath = "/api/v2/database/list"
    static let metadataPath = "/api/v2/database/metadata"
    static let checksumPath = "/api/v2/database/checksum"
    static let downloadsPath = "/api/v2/database/downloads"
    static let downloadPath = "/api/v2/database/download"
}
