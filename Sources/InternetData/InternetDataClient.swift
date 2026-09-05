import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Where the streaming `download(_:format:to:)` overload puts each chunk as it
/// arrives.
public typealias DownloadSink = (ArraySlice<UInt8>) async throws -> Void

/// A client for the InternetData API.
///
/// A `struct` rather than an `actor`: the client holds no mutable state at all,
/// so it is immutable and `Sendable` and its methods run on whatever executor
/// called them.
///
/// Nothing here is cached, deliberately. The catalog a key may see depends on
/// the licences its organization holds, so an answer cached against one key is
/// not an answer for another, and a listing is small and cheap next to the files
/// it describes.
public struct InternetDataClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://internetdata.io")!

    private let api: Client
    private let transport: any ClientTransport
    private let retries: Int

    public init(options: Options) {
        precondition(options.retries >= 0, "retries cannot be negative")

        // Resolved once, because the download path calls object storage straight
        // through the transport rather than through the generated client and has
        // to reach the same implementation a caller substituted.
        let transport = options.transport ?? DefaultTransport.shared
        self.api = Client(
            serverURL: options.baseURL,
            configuration: Configuration(dateTranscoder: LenientDateTranscoder()),
            transport: transport,
            middlewares: [AuthMiddleware(apiKey: options.apiKey), ErrorMiddleware()],
        )
        self.transport = transport
        self.retries = options.retries
    }

    /// A client that presents `apiKey` against production and takes every other
    /// default.
    public init(apiKey: String) {
        self.init(options: Options(apiKey: apiKey))
    }

    /// Every database your organization may see, with its licence beside it.
    ///
    /// The catalog is not the same for everyone. A database commissioned for a
    /// single customer is ABSENT from this list for every other organization
    /// rather than present with a `standing` of ``Database/Standing/unlicensed``,
    /// so what comes back is the whole of what you may know about. Do not cache
    /// one organization's listing and reuse it for another key, and do not
    /// reconstruct a catalog from anywhere else.
    public func list() async throws -> [Database] {
        try await withRetry(retries) {
            let output = try await api.listDatabases()
            guard case .ok(let ok) = output else {
                throw unexpected(output)
            }
            return try ok.body.json.databases.map(Database.init)
        }
    }

    /// What is inside one database: schema, sample rows, row count, sizes.
    ///
    /// Takes a versioned id from ``Database/versions``, e.g. `bogon_ip_v1`.
    public func metadata(id: String) async throws -> DatabaseMetadata {
        try await withRetry(retries) {
            let output = try await api.databaseMetadataV2(query: .init(id: id))
            guard case .ok(let ok) = output else {
                throw unexpected(output)
            }
            return DatabaseMetadata(try ok.body.json)
        }
    }

    /// The digests for one database file.
    ///
    /// Returns the whole set rather than one algorithm: which digest you want is
    /// your choice, not ours, and they arrive nested under `checksums` rather
    /// than at the top level.
    public func checksums(id: String, format: DatabaseFormat) async throws -> DatabaseChecksums {
        try await withRetry(retries) {
            let output = try await api.databaseChecksumV2(
                query: .init(id: id, format: .init(format)),
            )
            guard case .ok(let ok) = output else {
                throw unexpected(output)
            }
            return DatabaseChecksums(try ok.body.json.checksums)
        }
    }

    /// Your organization's recent download attempts, newest first.
    ///
    /// - Parameter limit: How many to return. Clamped to 200 by the API.
    public func downloads(limit: Int? = nil) async throws -> [Download] {
        try await withRetry(retries) {
            let output = try await api.listDownloads(query: .init(limit: limit))
            guard case .ok(let ok) = output else {
                throw unexpected(output)
            }
            return try ok.body.json.downloads.map(Download.init)
        }
    }

    /// The time-limited URL for one database file.
    ///
    /// The API answers `302` to object storage, and the link carries its own
    /// signature, so this is a download URL you can hand to something that holds
    /// no API key at all. It is returned rather than the bytes so you decide how
    /// to transfer a file that runs to gigabytes; the link authorizes the START
    /// of a transfer, so one already running is not interrupted when it lapses.
    ///
    /// The default transport refuses redirects outright. If you supplied your
    /// own and it follows them, this throws rather than handing back a URL,
    /// because by then the transport is holding the database.
    public func downloadURL(id: String, format: DatabaseFormat) async throws -> URL {
        try await withRetry(retries) {
            let output = try await api.downloadDatabaseV2(
                query: .init(id: id, format: .init(format)),
            )
            guard case .found(let found) = output else {
                throw unexpected(output)
            }
            guard let location = found.headers.location, let url = URL(string: location) else {
                throw InternetDataError(
                    kind: .serverError,
                    message: "the download redirect carried no usable Location header",
                    status: 302,
                )
            }
            return url
        }
    }

    /// Download one database file, streaming it to `fileURL`. Returns the number
    /// of bytes written.
    ///
    /// The bytes go to a neighboring `.part` file that is renamed on completion,
    /// so a transfer that dies half way leaves nothing that reads as a whole
    /// database. Nothing is held in memory beyond a single chunk, whatever the
    /// file weighs.
    ///
    /// A failure DURING the transfer surfaces as the underlying error rather
    /// than an ``InternetDataError``: a reset socket and a full disk are
    /// different problems, and flattening both into one kind hides the one you
    /// can do something about.
    @discardableResult
    public func download(
        _ id: String, format: DatabaseFormat, to fileURL: URL,
    ) async throws -> Int64 {
        let manager = FileManager.default
        let partial = fileURL.appendingPathExtension("part")
        guard manager.createFile(atPath: partial.path, contents: nil) else {
            throw InternetDataError(
                kind: .network, message: "could not create \(partial.path) to download into",
            )
        }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            let written = try await download(id, format: format) { chunk in
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            if manager.fileExists(atPath: fileURL.path) {
                try manager.removeItem(at: fileURL)
            }
            try manager.moveItem(at: partial, to: fileURL)
            return written
        } catch {
            try? handle.close()
            try? manager.removeItem(at: partial)
            throw error
        }
    }

    /// Download one database file, handing each chunk to `sink` as it arrives.
    /// Returns the number of bytes handed over.
    ///
    /// The counterpart to the file overload when the bytes are going somewhere
    /// else: a parser, an archive, another socket. The sink is awaited, so back
    /// pressure is real and a slow sink slows the transfer rather than queueing
    /// behind it.
    @discardableResult
    public func download(
        _ id: String, format: DatabaseFormat, to sink: DownloadSink,
    ) async throws -> Int64 {
        let body = try await databaseFile(id, format)
        var written: Int64 = 0
        for try await chunk in body {
            try await sink(chunk)
            written += Int64(chunk.count)
        }
        return written
    }

    /// Download one database file and hand back its bytes.
    ///
    /// **This holds the entire file in memory**, and the catalog spans seven
    /// orders of magnitude: `bogon_asn_v1` is 264 bytes while
    /// `resproxy_ip_90d_v1` runs to gigabytes, which will cost you that much
    /// resident memory and can fail outright. Reach for this at the small end,
    /// where the bytes are going straight into a parser; use the file overload of
    /// `download(_:format:to:)` for anything you have not measured, and
    /// ``metadata(id:)`` tells you which end you are at before you start.
    public func downloadBytes(_ id: String, format: DatabaseFormat) async throws -> Data {
        var data = Data()
        _ = try await download(id, format: format) { chunk in
            data.append(contentsOf: chunk)
        }
        return data
    }

    // Follows the 302 as a SECOND request straight to the transport, bypassing
    // the middleware chain that presents the API key: the presigned URL
    // authorizes itself, so forwarding the credential would hand it to a host
    // that has no business holding it.
    //
    // The body is returned unread. AsyncHTTPClient's deadline covers only the
    // time to the response HEAD - `executeCancellable` cancels the deadline task
    // the moment the continuation resumes - so the transport's 60 second default
    // is not a ceiling on a multi-gigabyte transfer, and reusing the injected
    // transport here is safe.
    private func databaseFile(_ id: String, _ format: DatabaseFormat) async throws -> HTTPBody {
        let url = try await downloadURL(id: id, format: format)
        let (origin, path) = try split(url)
        return try await withRetry(retries) {
            let (response, body) = try await transport.send(
                HTTPRequest(method: .get, scheme: nil, authority: nil, path: path),
                body: nil,
                baseURL: origin,
                operationID: "downloadDatabaseFile",
            )
            let status = Int(response.status.code)
            guard (200..<300).contains(status) else {
                // Left unread: the status is what separates a lapsed link from a
                // refused one, and nothing bounds the size of an error body.
                throw InternetDataError.from(
                    status: status,
                    headers: response.headerFields,
                    body: [],
                    fallback: "object storage refused the download link with status \(status)",
                )
            }
            guard let body else {
                throw InternetDataError(
                    kind: .serverError, message: "object storage answered with no body",
                    status: status,
                )
            }
            return body
        }
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
        /// followed; see ``InternetDataClient/downloadURL(id:format:)``.
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

private func unexpected(_ output: some Sendable) -> InternetDataError {
    InternetDataError(kind: .serverError, message: "unexpected response: \(output)")
}

// A transport is handed a base URL and a path, so the presigned URL has to come
// apart into the two. The query carries the signature and cannot be dropped.
private func split(_ url: URL) throws -> (origin: URL, path: String) {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw InternetDataError(kind: .serverError, message: "unreadable download URL")
    }
    let path = components.percentEncodedPath
    let query = components.percentEncodedQuery
    components.percentEncodedPath = ""
    components.percentEncodedQuery = nil
    components.fragment = nil
    guard let origin = components.url else {
        throw InternetDataError(kind: .serverError, message: "unreadable download URL")
    }
    return (origin, query.map { "\(path)?\($0)" } ?? path)
}
