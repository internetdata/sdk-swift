import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Where a streaming ``DatabaseAPI/download(_:format:to:)`` puts each chunk as
/// it arrives.
public typealias DownloadSink = (ArraySlice<UInt8>) async throws -> Void

/// The licensed database downloads. Access is granted by contract, not
/// self-serve.
///
/// Reached as ``InternetDataClient/database``; there is no reason to build one
/// directly. It is the only surface the API has, and it still sits behind a
/// namespace so that a codebase holding both this client and the VPNDetection
/// one spells the same call the same way in both.
///
/// Nothing here is cached, deliberately. The catalog a key may see depends on
/// the licenses its organization holds, so an answer cached against one key is
/// not an answer for another, and a listing is small and cheap next to the files
/// it describes.
///
/// Every call here that asks the API a question takes a `timeout`, bounding each
/// ATTEMPT of that one call in place of the client's. The transfers take none
/// and there is no argument to pass: a database runs to gigabytes and minutes,
/// so any bound that suits a JSON call would abandon a healthy download, and a
/// call that tries to set one does not compile rather than being quietly
/// ignored.
public struct DatabaseAPI: Sendable {
    private let api: Client
    private let transport: any ClientTransport
    private let retries: Int
    private let timeout: Duration

    init(api: Client, transport: any ClientTransport, retries: Int, timeout: Duration) {
        self.api = api
        self.transport = transport
        self.retries = retries
        self.timeout = timeout
    }

    /// Every database your organization may see, with its license beside it.
    ///
    /// This is the server's answer for this key, so a listing held from one key
    /// is not an answer for another. Do not cache one organization's listing and
    /// reuse it for another key.
    ///
    /// - Parameter timeout: Overrides the client's ``InternetDataClient/Options/timeout``
    ///   for each attempt of this call.
    public func list(timeout: Duration? = nil) async throws -> [Database] {
        try await withRetry(retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.listDatabases()
                guard case .ok(let ok) = output else {
                    throw unexpected(output)
                }
                return try ok.body.json.databases.map(Database.init)
            }
        }
    }

    /// What is inside one database: schema, sample rows, row count, sizes.
    ///
    /// Takes a versioned ID from ``Database/versions``, e.g. `bogon_ip_v1`.
    ///
    /// - Parameter timeout: Overrides the client's ``InternetDataClient/Options/timeout``
    ///   for each attempt of this call.
    public func metadata(id: String, timeout: Duration? = nil) async throws -> DatabaseMetadata {
        try await withRetry(retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.databaseMetadataV2(query: .init(id: id))
                guard case .ok(let ok) = output else {
                    throw unexpected(output)
                }
                return try DatabaseMetadata(ok.body.json)
            }
        }
    }

    /// The digests for one database file.
    ///
    /// Returns the whole set rather than one algorithm: which digest you want is
    /// your choice, not ours, and they arrive nested under `checksums` rather
    /// than at the top level.
    ///
    /// - Parameter timeout: Overrides the client's ``InternetDataClient/Options/timeout``
    ///   for each attempt of this call.
    public func checksums(
        id: String, format: DatabaseFormat, timeout: Duration? = nil,
    ) async throws -> DatabaseChecksums {
        try checkFormat(format)
        return try await withRetry(retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.databaseChecksumV2(
                    query: .init(id: id, format: format.rawValue),
                )
                guard case .ok(let ok) = output else {
                    throw unexpected(output)
                }
                return DatabaseChecksums(try ok.body.json.checksums)
            }
        }
    }

    /// Your organization's recent download attempts, newest first.
    ///
    /// - Parameters:
    ///   - limit: How many to return. Clamped to 200 by the API.
    ///   - timeout: Overrides the client's ``InternetDataClient/Options/timeout``
    ///     for each attempt of this call.
    public func downloads(limit: Int? = nil, timeout: Duration? = nil) async throws -> [Download] {
        try await withRetry(retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.listDownloads(query: .init(limit: limit))
                guard case .ok(let ok) = output else {
                    throw unexpected(output)
                }
                return try ok.body.json.downloads.map(Download.init)
            }
        }
    }

    /// The time-limited URL for one database file.
    ///
    /// The API answers `302` to object storage, and the link carries its own
    /// signature, so this is a download URL you can hand to something that holds
    /// no API key at all. It is returned rather than the bytes so you decide how
    /// to transfer a file that runs to gigabytes. The link only has to be valid
    /// when a transfer starts, so one already running isn't cut off when it lapses.
    ///
    /// The default transport refuses redirects outright. If you supplied your
    /// own and it follows them, this throws rather than handing back a URL,
    /// because by then the transport is holding the database.
    ///
    /// - Parameter timeout: Overrides the client's ``InternetDataClient/Options/timeout``
    ///   for each attempt at MINTING the link, which is an ordinary API request.
    ///   It says nothing about the transfer you then run with it.
    public func downloadURL(
        id: String, format: DatabaseFormat, timeout: Duration? = nil,
    ) async throws -> URL {
        try await downloadURL(id: id, format: format, build: nil, timeout: timeout)
    }

    /// ``downloadURL(id:format:timeout:)`` for one build of the database, as a
    /// `database.updated` webhook names it (`20261105.0t53s5`), so the file is
    /// the one whose `sha256` the webhook carries. `nil` or empty is the build
    /// that is live. A build is kept 7 days; past that the call throws
    /// ``InternetDataErrorKind/badRequest`` with the message `BUILD_GONE`.
    public func downloadURL(
        id: String, format: DatabaseFormat, build: String?, timeout: Duration? = nil,
    ) async throws -> URL {
        try checkFormat(format)
        let named = build?.isEmpty == false ? build : nil
        return try await withRetry(retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let served = ServedLocation.Capture()
                let output = try await ServedLocation.$current.withValue(served) {
                    try await api.downloadDatabaseV2(
                        query: .init(id: id, format: format.rawValue, build: named),
                    )
                }
                guard case .found = output else {
                    throw unexpected(output)
                }
                // The header as served: the generated `found.headers.location` is
                // percent-decoded, which changes what the link's signature covers.
                guard let location = served.location, let url = URL(string: location) else {
                    throw InternetDataError(
                        kind: .serverError,
                        message: "the download redirect carried no usable Location header",
                        status: 302,
                    )
                }
                return url
            }
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
        try await download(id, format: format, build: nil, to: fileURL)
    }

    /// The file overload of `download(_:format:to:)` for one build of
    /// the database, as ``downloadURL(id:format:build:timeout:)`` takes it.
    @discardableResult
    public func download(
        _ id: String, format: DatabaseFormat, build: String?, to fileURL: URL,
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
            let written = try await download(id, format: format, build: build) { chunk in
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
        try await download(id, format: format, build: nil, to: sink)
    }

    /// The streaming overload for one build of the database, as
    /// ``downloadURL(id:format:build:timeout:)`` takes it.
    @discardableResult
    public func download(
        _ id: String, format: DatabaseFormat, build: String?, to sink: DownloadSink,
    ) async throws -> Int64 {
        let body = try await databaseFile(id, format, build)
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
    /// ``metadata(id:timeout:)`` tells you which end you are at before you start.
    public func downloadBytes(_ id: String, format: DatabaseFormat) async throws -> Data {
        try await downloadBytes(id, format: format, build: nil)
    }

    /// ``downloadBytes(_:format:)`` for one build of the database, as
    /// ``downloadURL(id:format:build:timeout:)`` takes it.
    public func downloadBytes(
        _ id: String, format: DatabaseFormat, build: String?,
    ) async throws -> Data {
        var data = Data()
        _ = try await download(id, format: format, build: build) { chunk in
            data.append(contentsOf: chunk)
        }
        return data
    }

    // Follows the 302 as a SECOND request straight to the transport, bypassing
    // the middleware chain that presents the API key: the presigned URL
    // authorizes itself, so forwarding the credential would hand it to a host
    // that has no business holding it.
    //
    // The body is returned unread, so the attempt's deadline ends at the response
    // head and a multi-gigabyte transfer is never racing it.
    private func databaseFile(
        _ id: String, _ format: DatabaseFormat, _ build: String?,
    ) async throws -> HTTPBody {
        let url = try await downloadURL(id: id, format: format, build: build)
        let (origin, path) = try split(url)
        return try await withRetry(retries) {
            try await withDeadline(timeout) {
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

/// The formats a database is published in.
///
/// Not every database is built in every format: the `_provider` catalogs are
/// keyed by provider ID rather than by IP range, so no MMDB exists for them, and
/// asking for one is a `badRequest` rather than a gap. A format this release was
/// not built with reads as served in an answer, and is refused as a
/// ``InternetDataErrorKind/badRequest`` before any request names it.
public struct DatabaseFormat: Vocabulary {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let csvgz = DatabaseFormat(rawValue: "csvgz")
    public static let mmdb = DatabaseFormat(rawValue: "mmdb")

    public static let known: [DatabaseFormat] = [.csvgz, .mmdb]
}

/// One database FAMILY, with your organization's license beside it.
///
/// A license is held against the family, while a download names a version, so
/// the IDs the download, checksum and metadata methods take come from
/// ``versions`` rather than from ``base``.
public struct Database: Sendable, Hashable {
    /// The family, e.g. `vpn_ip`. What a license is held against.
    public let base: String
    public let name: String
    /// One line on what the newest version contains.
    public let summary: String
    /// Where your organization stands on this family.
    public let standing: Standing
    /// An Open database: free under CC BY-SA 4.0. Every organization holds a
    /// `standard` license to it from the start, which ``standing`` and
    /// ``licenseType`` report like any other.
    public let open: Bool
    /// What your license permits you to do with the data, or `nil` when there is
    /// no license.
    public let licenseType: LicenseType?
    public let starts: Date?
    /// `nil` when the license has no end date, or when there is none.
    public let expires: Date?
    /// When a rolling license next renews. `nil` when the license has no defined
    /// term, when ``expires`` sets a hard stop instead, and when there is none.
    public let renewsAt: Date?
    /// The last day notice of non-renewal can be given for the term ending at
    /// ``renewsAt``. `nil` whenever that is, and when the agreement records no
    /// notice period.
    public let noticeDueAt: Date?
    /// Every published version of this family, oldest first. Old versions are
    /// frozen rather than migrated, so both stay downloadable.
    public let versions: [DatabaseVersion]

    /// Where an organization stands on one family. A standing this release was
    /// not built with reads as served.
    public struct Standing: Vocabulary {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// A live grant.
        public static let licensed = Standing(rawValue: "licensed")
        /// A term that has ended.
        public static let expired = Standing(rawValue: "expired")
        /// Published, but never bought.
        public static let unlicensed = Standing(rawValue: "unlicensed")

        public static let known: [Standing] = [.licensed, .expired, .unlicensed]
    }

    /// What a license permits. A license type this release was not built with
    /// reads as served.
    public struct LicenseType: Vocabulary {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let evaluation = LicenseType(rawValue: "evaluation")
        public static let standard = LicenseType(rawValue: "standard")
        public static let redistribute = LicenseType(rawValue: "redistribute")

        public static let known: [LicenseType] = [.evaluation, .standard, .redistribute]
    }
}

/// One published version of a database family.
public struct DatabaseVersion: Sendable, Hashable {
    /// The versioned ID, e.g. `vpn_ip_v1`. This is what a download takes.
    public let id: String
    public let version: Int
    public let summary: String
    /// The formats this version is BUILT in.
    public let formats: [DatabaseFormat]
    /// The formats an evaluation sample is published in, or `nil` when none is.
    public let sampleFormats: [DatabaseFormat]?
}

/// What is inside one database.
///
/// Poll this to decide whether today's build is worth fetching: it carries
/// ``updated`` and ``entries`` without downloading anything, and ``size`` is
/// what a caller should budget a transfer against.
public struct DatabaseMetadata: Sendable, Hashable {
    public let id: String
    /// How often a new build is published.
    public let updateFreq: String?
    /// The build date, as `YYYY-MM-DD`. A calendar date rather than an instant,
    /// so it is left as the string the API published, once it is checked to
    /// name a day that exists.
    public let updated: String
    /// Row count in the current build.
    public let entries: Int64
    /// Columns, keyed by format.
    public let schema: [String: [DatabaseColumn]]
    /// A few real rows, keyed by format.
    public let sample: [String: [[String: JSONValue]]]
    /// Bytes per format.
    public let size: [String: Int64]
    /// Bytes per format of the evaluation sample, where one is published.
    public let sampleSize: [String: Int64]?
    /// Row count in the evaluation sample.
    public let sampleEntries: Int?
}

/// One column of a database, as published.
public struct DatabaseColumn: Sendable, Hashable {
    public let name: String
    public let type: String
    public let description: String?
}

/// The digests published alongside one database file, so a transfer can be
/// verified. All four are always published.
public struct DatabaseChecksums: Sendable, Hashable {
    public let md5: String
    public let sha1: String
    public let sha256: String
    public let sha512: String
}

/// One download ATTEMPT by your organization, refusals included: a denial is
/// what answers "it stopped working", and its absence answers nothing.
public struct Download: Sendable, Hashable {
    /// The versioned database ID that was asked for.
    public let datasetId: String
    public let format: String
    public let outcome: Outcome
    /// The evaluation sample rather than the database itself.
    public let sample: Bool
    /// A download of an Open database.
    public let open: Bool
    /// Object size at redirect time, NOT bytes delivered: the transfer is a
    /// presigned redirect straight to object storage, so the API never observes
    /// how much of it was taken.
    public let bytes: Int64?
    public let httpStatus: Int?
    /// The key that made the request, or `nil` when it could not be resolved.
    public let apikeyId: String?
    public let clientIp: String?
    public let userAgent: String?
    public let created: Date

    /// How the attempt ended. An outcome this release was not built with reads
    /// as served; `unknown` is one the API serves, a database it does not know.
    public struct Outcome: Vocabulary {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let ok = Outcome(rawValue: "ok")
        public static let unauthorized = Outcome(rawValue: "unauthorized")
        public static let denied = Outcome(rawValue: "denied")
        public static let expired = Outcome(rawValue: "expired")
        public static let unknown = Outcome(rawValue: "unknown")
        public static let unavailable = Outcome(rawValue: "unavailable")

        public static let known: [Outcome] = [.ok, .unauthorized, .denied, .expired, .unknown, .unavailable]
    }
}

extension Database {
    init(_ wire: WireDatabase) throws {
        self.base = wire.base
        self.name = wire.name
        self.summary = wire.summary
        self.standing = try vocabulary(wire.standing, "standing")
        self.open = wire.open
        self.licenseType = try wire.licenseType.map { try vocabulary($0, "license_type") }
        self.starts = wire.starts
        self.expires = wire.expires
        self.renewsAt = wire.renewsAt
        self.noticeDueAt = wire.noticeDueAt
        self.versions = try wire.versions.map(DatabaseVersion.init)
    }
}

extension DatabaseVersion {
    init(_ wire: Components.Schemas.DatabaseVersion) throws {
        self.id = wire.id
        self.version = wire.version
        self.summary = wire.summary
        self.formats = try wire.formats.map { try vocabulary($0, "format") }
        self.sampleFormats = try wire.sampleFormats?.map { try vocabulary($0, "format") }
    }
}

/// Refuses a format this release was not built with before any request names
/// it: the API publishes the formats it builds, and a request for another is
/// one it never answers with a file.
private func checkFormat(_ format: DatabaseFormat) throws {
    guard format.isKnown else {
        let known = DatabaseFormat.known.map(\.rawValue).joined(separator: ", ")
        throw InternetDataError(
            kind: .badRequest, message: "format \(format.rawValue.debugDescription) is not one of \(known)",
        )
    }
}

extension DatabaseMetadata {
    init(_ wire: Components.Schemas.DatabaseMetadata) throws {
        // `format: date` reaches the generated type as a plain string.
        guard RFC3339.isFullDate(wire.updated) else {
            throw unreadable("updated \(wire.updated.debugDescription) is no YYYY-MM-DD date")
        }
        self.id = wire.id
        self.updateFreq = wire.updateFreq
        self.updated = wire.updated
        self.entries = wire.entries
        self.schema = wire.schema.additionalProperties.mapValues { $0.map(DatabaseColumn.init) }
        self.sample = (wire.sample?.additionalProperties ?? [:]).mapValues { rows in
            rows.map { $0.value.mapValues(JSONValue.init) }
        }
        self.size = wire.size.additionalProperties
        self.sampleSize = wire.sampleSize?.additionalProperties
        self.sampleEntries = wire.sampleEntries
    }
}

extension DatabaseColumn {
    init(_ wire: Components.Schemas.DatabaseMetadataColumn) {
        self.name = wire.name
        self.type = wire._type
        self.description = wire.description
    }
}

extension DatabaseChecksums {
    init(_ wire: Components.Schemas.DbChecksums) {
        self.md5 = wire.md5
        self.sha1 = wire.sha1
        self.sha256 = wire.sha256
        self.sha512 = wire.sha512
    }
}

extension Download {
    init(_ wire: WireDownload) throws {
        self.datasetId = wire.datasetId
        self.format = wire.format
        self.outcome = try vocabulary(wire.outcome, "outcome")
        self.sample = wire.sample
        self.open = wire.open
        self.bytes = wire.bytes
        self.httpStatus = wire.httpStatus
        self.apikeyId = wire.apikeyId
        self.clientIp = wire.clientIp
        self.userAgent = wire.userAgent
        self.created = wire.created
    }
}

private func unexpected(_ output: some Sendable) -> InternetDataError {
    InternetDataError(kind: .serverError, message: "unexpected response: \(output)")
}

// A 200 the generated decoder read, holding a value the spec does not allow:
// retried like any other answer the call cannot read.
private func unreadable(_ detail: String) -> InternetDataError {
    InternetDataError(
        kind: .serverError, message: "the response was not the answer this call returns: \(detail)", status: 200,
    )
}

/// `Database` as decoded, in place of the generated type (`typeOverrides` in
/// the generator config): the generated one reads `license_type` as an enum,
/// which refuses a license type the API added since. `standing` and each
/// version's formats arrive as strings by the same config.
struct WireDatabase: Codable, Hashable, Sendable {
    var base: String
    var name: String
    var summary: String
    var standing: String
    var open: Bool
    var licenseType: String?
    var starts: Date?
    var expires: Date?
    var renewsAt: Date?
    var noticeDueAt: Date?
    var versions: [Components.Schemas.DatabaseVersion]

    enum CodingKeys: String, CodingKey {
        case base
        case name
        case summary
        case standing
        case open
        case licenseType = "license_type"
        case starts
        case expires
        case renewsAt = "renews_at"
        case noticeDueAt = "notice_due_at"
        case versions
    }
}

/// `Download` as decoded, in place of the generated type, for its `outcome`.
struct WireDownload: Codable, Hashable, Sendable {
    var datasetId: String
    var format: String
    var outcome: String
    var sample: Bool
    var open: Bool
    var bytes: Int64?
    var httpStatus: Int?
    var apikeyId: String?
    var clientIp: String?
    var userAgent: String?
    var created: Date

    enum CodingKeys: String, CodingKey {
        case datasetId = "dataset_id"
        case format
        case outcome
        case sample
        case open
        case bytes
        case httpStatus = "http_status"
        case apikeyId = "apikey_id"
        case clientIp = "client_ip"
        case userAgent = "user_agent"
        case created
    }
}
