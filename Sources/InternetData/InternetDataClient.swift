import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A client for the InternetData API.
///
/// A `struct` rather than an `actor`: the client holds no mutable state at all,
/// so it is immutable and `Sendable` and its methods run on whatever executor
/// called them.
///
/// Every call lives under ``database``. The downloads are the whole of this API
/// today, so a second level buys nothing on its own; it is here because the
/// sibling VPNDetection client spells the same seven calls the same way, and a
/// codebase holding both should not have to remember which one is flat.
public struct InternetDataClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://internetdata.io")!

    /// The licensed database downloads.
    public let database: DatabaseAPI

    public init(options: Options) {
        precondition(options.retries >= 0, "retries cannot be negative")

        // Resolved once, because the download path calls object storage straight
        // through the transport rather than through the generated client and has
        // to reach the same implementation a caller substituted.
        let transport = options.transport ?? DefaultTransport.shared
        let api = Client(
            serverURL: options.baseURL,
            configuration: Configuration(dateTranscoder: LenientDateTranscoder()),
            transport: transport,
            middlewares: [AuthMiddleware(apiKey: options.apiKey), ErrorMiddleware()],
        )
        self.database = DatabaseAPI(api: api, transport: transport, retries: options.retries)
    }

    /// A client that presents `apiKey` against production and takes every other
    /// default.
    public init(apiKey: String) {
        self.init(options: Options(apiKey: apiKey))
    }
}

extension InternetDataClient {
    /// How a client behaves. Everything but the key has a default.
    public struct Options: Sendable {
        /// Your API key, carrying the `db.download` scope. Every endpoint here
        /// needs one: there is no unauthenticated tier.
        public var apiKey: String
        public var baseURL: URL
        /// Retry attempts for a transient failure. Default 2.
        public var retries: Int
        /// Override the HTTP implementation. Anything you supply owns its own
        /// redirect policy, and the download endpoint's `302` must not be
        /// followed; see ``DatabaseAPI/downloadURL(id:format:)``.
        public var transport: (any ClientTransport)?

        public init(
            apiKey: String,
            baseURL: URL = InternetDataClient.defaultBaseURL,
            retries: Int = 2,
            transport: (any ClientTransport)? = nil,
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.retries = retries
            self.transport = transport
        }
    }
}
