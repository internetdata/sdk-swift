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
/// the licences its organization holds, so an answer cached against one key is
/// not an answer for another, and a listing is small and cheap next to the files
/// it describes.
public struct DatabaseAPI: Sendable {
    private let api: Client
    private let transport: any ClientTransport
    private let retries: Int

    init(api: Client, transport: any ClientTransport, retries: Int) {
        self.api = api
        self.transport = transport
        self.retries = retries
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
/// keyed by provider id rather than by IP range, so no MMDB exists for them, and
/// asking for one is a `badRequest` rather than a gap.
public enum DatabaseFormat: String, Sendable, Hashable, CaseIterable {
    case csvgz
    case mmdb
}

/// One database FAMILY, with your organization's licence beside it.
///
/// A licence is held against the family, while a download names a version, so
/// the ids the download, checksum and metadata methods take come from
/// ``versions`` rather than from ``base``.
public struct Database: Sendable, Hashable {
    /// The family, e.g. `vpn_ip`. What a licence is held against.
    public let base: String
    public let name: String
    /// One line on what the newest version contains.
    public let summary: String
    /// Where your organization stands on this family.
    public let standing: Standing
    /// What your licence permits you to do with the data, or `nil` when there is
    /// no licence.
    public let license_type: LicenseType?
    public let starts: Date?
    /// `nil` when the licence has no end date, or when there is none.
    public let expires: Date?
    /// Every published version of this family, oldest first. Old versions are
    /// frozen rather than migrated, so both stay downloadable.
    public let versions: [DatabaseVersion]

    /// Where an organization stands on one family.
    public enum Standing: String, Sendable, Hashable, CaseIterable {
        /// A live grant.
        case licensed
        /// A term that has ended.
        case expired
        /// Published, but never bought.
        case unlicensed
    }

    /// What a licence permits.
    public enum LicenseType: String, Sendable, Hashable, CaseIterable {
        case evaluation
        case standard
        case redistribute
    }
}

/// One published version of a database family.
public struct DatabaseVersion: Sendable, Hashable {
    /// The versioned id, e.g. `vpn_ip_v1`. This is what a download takes.
    public let id: String
    public let version: Int
    public let summary: String
    /// The formats this version is BUILT in.
    public let formats: [DatabaseFormat]
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
    /// so it is left as the string the API published.
    public let updated: String
    /// Row count in the current build.
    public let entries: Int64
    /// Columns, keyed by format.
    public let schema: [String: [DatabaseColumn]]
    /// A few real rows, keyed by format.
    public let sample: [String: [[String: JSONValue]]]
    /// Bytes per format.
    public let size: [String: Int64]
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
    /// The versioned database id that was asked for.
    public let datasetId: String
    public let format: String
    public let outcome: Outcome
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

    public enum Outcome: String, Sendable, Hashable, CaseIterable {
        case ok
        case unauthorized
        case denied
        case expired
        case unknown
        case unavailable
    }
}

extension Database {
    init(_ wire: Components.Schemas.Database) {
        self.base = wire.base
        self.name = wire.name
        self.summary = wire.summary
        self.standing = Standing(wire.standing)
        self.license_type = wire.license_type.flatMap(LicenseType.init)
        self.starts = wire.starts
        self.expires = wire.expires
        self.versions = wire.versions.map(DatabaseVersion.init)
    }
}

extension Database.Standing {
    // Exhaustive rather than `init(rawValue:)`, so a standing added to the spec
    // is a compile error here instead of silently becoming `unlicensed`.
    init(_ wire: Components.Schemas.Database.StandingPayload) {
        switch wire {
        case .licensed: self = .licensed
        case .expired: self = .expired
        case .unlicensed: self = .unlicensed
        }
    }
}

extension Database.LicenseType {
    /// `nil` for the generator's `_empty_` case.
    ///
    /// The spec spells "no licence" as `nullable: true` PLUS a `null` member of
    /// the enum, and the generator turns that member into an empty-string case
    /// alongside the three real ones. A `null` on the wire decodes as the absent
    /// Optional rather than as that case, so `_empty_` should be unreachable;
    /// mapping it to "no licence" rather than trapping keeps a surprise from
    /// becoming a crash in a caller's process.
    init?(_ wire: Components.Schemas.Database.LicenseTypePayload) {
        switch wire {
        case .evaluation: self = .evaluation
        case .standard: self = .standard
        case .redistribute: self = .redistribute
        case ._empty_: return nil
        }
    }
}

extension DatabaseVersion {
    init(_ wire: Components.Schemas.DatabaseVersion) {
        self.id = wire.id
        self.version = wire.version
        self.summary = wire.summary
        self.formats = wire.formats.map(DatabaseFormat.init)
    }
}

extension DatabaseFormat {
    init(_ wire: Components.Schemas.DatabaseVersion.FormatsPayloadPayload) {
        switch wire {
        case .csvgz: self = .csvgz
        case .mmdb: self = .mmdb
        }
    }
}

// One conversion for both operations that take a format: the spec declares the
// parameter once and both `download` and `checksum` reference it.
extension Components.Parameters.DbFormat {
    init(_ format: DatabaseFormat) {
        switch format {
        case .csvgz: self = .csvgz
        case .mmdb: self = .mmdb
        }
    }
}

extension DatabaseMetadata {
    init(_ wire: Components.Schemas.DatabaseMetadata) {
        self.id = wire.id
        self.updateFreq = wire.updateFreq
        self.updated = wire.updated
        self.entries = wire.entries
        self.schema = wire.schema.additionalProperties.mapValues { $0.map(DatabaseColumn.init) }
        self.sample = (wire.sample?.additionalProperties ?? [:]).mapValues { rows in
            rows.map { $0.value.mapValues(JSONValue.init) }
        }
        self.size = wire.size.additionalProperties
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
    init(_ wire: Components.Schemas.Download) {
        self.datasetId = wire.datasetId
        self.format = wire.format
        self.outcome = Outcome(wire.outcome)
        self.bytes = wire.bytes
        self.httpStatus = wire.httpStatus
        self.apikeyId = wire.apikeyId
        self.clientIp = wire.clientIp
        self.userAgent = wire.userAgent
        self.created = wire.created
    }
}

extension Download.Outcome {
    init(_ wire: Components.Schemas.Download.OutcomePayload) {
        switch wire {
        case .ok: self = .ok
        case .unauthorized: self = .unauthorized
        case .denied: self = .denied
        case .expired: self = .expired
        case .unknown: self = .unknown
        case .unavailable: self = .unavailable
        }
    }
}

private func unexpected(_ output: some Sendable) -> InternetDataError {
    InternetDataError(kind: .serverError, message: "unexpected response: \(output)")
}
