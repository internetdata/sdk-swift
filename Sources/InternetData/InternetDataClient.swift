import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A client for the InternetData API.
///
/// A `struct` rather than an `actor`: the client holds no mutable state at all,
/// so it is immutable and `Sendable` and its methods run on whatever executor
/// called them.
///
/// The database calls live under ``database`` and the OAuth sign-in under
/// ``oauth``. The second level is there because the sibling VPNDetection client
/// spells the same calls the same way, and a codebase holding both should not
/// have to remember which one is flat.
public struct InternetDataClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://internetdata.io")!

    /// The licensed database downloads.
    public let database: DatabaseAPI

    /// Sign a person in with OAuth's device flow and receive one of their API
    /// keys. Its requests never carry this client's key.
    public let oauth: OauthAPI

    public init(options: Options = Options()) {
        precondition(options.retries >= 0, "retries cannot be negative")
        precondition(options.timeout > .zero, "timeout must be positive")
        precondition(options.timeout <= maxTimeout, "timeout is longer than the runtime can count")

        // Attached only when there is a key, so a keyless client sends no
        // `Authorization` header rather than `Bearer ` with nothing behind it -
        // which is what an unset `${{ secrets.X }}` interpolates to, and which
        // the API answers 401 to rather than treating as no credential at all.
        var middlewares: [any ClientMiddleware] = []
        if let apiKey = options.apiKey, apiKey.isEmpty == false {
            middlewares.append(AuthMiddleware(apiKey: apiKey))
        }
        middlewares.append(ErrorMiddleware())

        // Resolved once, because the download path calls object storage straight
        // through the transport rather than through the generated client and has
        // to reach the same implementation a caller substituted.
        let transport = options.transport ?? DefaultTransport.shared
        let baseURL = withoutTrailingSlashes(options.baseURL)
        let api = Client(
            serverURL: baseURL,
            configuration: Configuration(dateTranscoder: LenientDateTranscoder()),
            transport: transport,
            middlewares: middlewares,
        )
        self.database = DatabaseAPI(
            api: api, transport: transport, retries: options.retries, timeout: options.timeout,
        )
        self.oauth = OauthAPI(
            transport: transport, baseURL: baseURL, retries: options.retries,
            timeout: options.timeout,
        )
    }

    /// A client that presents `apiKey` against production and takes every other
    /// default.
    public init(apiKey: String) {
        self.init(options: Options(apiKey: apiKey))
    }
}

extension InternetDataClient {
    /// How a client behaves. Everything has a default.
    public struct Options: Sendable {
        /// Your API key, carrying the `db.download` scope. Optional: omit it and
        /// no `Authorization` header is sent at all. Every database endpoint
        /// published today answers `401` without one, but that is what the API
        /// serves rather than a property of its shape. ``oauth`` takes none.
        public var apiKey: String?
        /// Where the API is served. Default ``InternetDataClient/defaultBaseURL``.
        ///
        /// A trailing slash is dropped. Every path this client appends begins with
        /// one and the transport appends it to whatever path the base URL already
        /// carries, so `https://internetdata.io/` would ask for `//api/v2/...`.
        /// That is a different path to the server: production answers it with a
        /// `308` the default transport refuses to follow, so every call would fail.
        public var baseURL: URL
        /// Retry attempts for a transient failure. Default 2.
        public var retries: Int
        /// How long one attempt may take, from sending the request to decoding
        /// the answer. Default 30 seconds. Per ATTEMPT, so a retried call may
        /// take longer in total. A database transfer is bounded only until its
        /// response head arrives, so a download that takes minutes is not cut off.
        ///
        /// Must be positive, and short enough for the concurrency runtime to count
        /// to. Zero, a negative duration and one near the top of `Int64` seconds
        /// are each a bound no attempt could meet; a call given one refuses it as
        /// ``InternetDataErrorKind/badRequest`` rather than failing on the wire.
        public var timeout: Duration
        /// Override the HTTP implementation. Anything you supply owns its own
        /// redirect policy, and the download endpoint's `302` must not be
        /// followed; see ``DatabaseAPI/downloadURL(id:format:timeout:)``.
        public var transport: (any ClientTransport)?

        public init(
            apiKey: String? = nil,
            baseURL: URL = InternetDataClient.defaultBaseURL,
            retries: Int = 2,
            timeout: Duration = .seconds(30),
            transport: (any ClientTransport)? = nil,
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.retries = retries
            self.timeout = timeout
            self.transport = transport
        }
    }
}

// Every path the generated client appends begins with a slash, and the transport
// appends it to whatever path the base URL already carries, so a base URL ending
// in one asks for `//api/v2/...`. That is a different path to the server, which
// answers it with a `308` the default transport refuses to follow, so every call
// fails. Every trailing slash goes rather than one: dropping a single slash
// still doubles `.../`.
private func withoutTrailingSlashes(_ url: URL) -> URL {
    var text = url.absoluteString
    while text.hasSuffix("/") {
        text.removeLast()
    }
    return URL(string: text) ?? url
}
