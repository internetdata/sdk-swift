import AsyncHTTPClient
import Foundation
import HTTPTypes
import OpenAPIAsyncHTTPClient
import InternetData
import OpenAPIRuntime
import Testing

/// The staging fixtures the suite shares: the credential, one client, and the
/// transport that proves what each request carried.

let staging = URL(string: "https://staging.internetdata.io")!

/// The one credential this suite needs.
///
/// Every v2 endpoint requires a bearer key, so without it there is nothing at
/// all to exercise. A secret that does not exist interpolates to an EMPTY string
/// in CI rather than leaving the variable unset, so a plain `!= nil` check never
/// fires and an empty key is sent as no key at all; emptiness is what counts as
/// absent here.
enum Credential {
    static let secret = "INTERNETDATA_STAGING_KEY"

    static var key: String {
        (ProcessInfo.processInfo.environment[secret] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the suite cannot run, or `nil` when it can.
    static var skipReason: String? {
        key.isEmpty ? "\(secret) is not set, so nothing can be exercised" : nil
    }

    /// The trait that skips, naming the secret, rather than failing a run that
    /// was never given the credential. swift-testing has no runtime skip API, so
    /// this is a trait on every test rather than a guard inside one.
    static var needsKey: ConditionTrait {
        .enabled(if: skipReason == nil, Comment(rawValue: skipReason ?? "the key is present"))
    }
}

func stagingClient(transport: RecordingTransport) -> InternetDataClient {
    InternetDataClient(
        options: .init(apiKey: Credential.key, baseURL: staging, transport: transport),
    )
}

/// A transport that records DERIVED facts about each request.
///
/// Only derived facts leave here. A failing expectation prints its operands and
/// these logs are public, so what is remembered is WHETHER the key was carried;
/// the request and the key itself never escape.
final class RecordingTransport: ClientTransport {
    struct Fact: Sendable, Equatable {
        let origin: String
        let path: String
        let carriedKey: Bool
    }

    private let key: String
    private let inner: any ClientTransport
    private let log = Log()

    init(key: String = Credential.key, inner: any ClientTransport = SharedTransport.value) {
        self.key = key
        self.inner = inner
    }

    var facts: [Fact] {
        get async { await log.facts }
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? "/"
        let carried =
            !key.isEmpty
            && (path.contains(key) || request.headerFields.contains { $0.value.contains(key) })
        await log.record(
            Fact(
                origin: baseURL.absoluteString,
                path: String(path.split(separator: "?", maxSplits: 1)[0]),
                carriedKey: carried,
            ),
        )
        return try await inner.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }

    private actor Log {
        var facts: [Fact] = []

        func record(_ fact: Fact) {
            facts.append(fact)
        }
    }
}

/// One `HTTPClient` for the process, held in a global so it is never
/// deallocated: AsyncHTTPClient's `deinit` traps in a debug build when a client
/// was not shut down. Redirects are refused, matching the library's own default
/// transport, because the download endpoint's `302` must reach the library
/// rather than the transport.
enum SharedTransport {
    static let value: any ClientTransport = AsyncHTTPClientTransport(
        configuration: .init(
            client: HTTPClient(
                eventLoopGroupProvider: .singleton,
                configuration: HTTPClient.Configuration(redirectConfiguration: .disallow),
            ),
        ),
    )
}
