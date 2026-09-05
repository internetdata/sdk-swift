import Foundation

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
    public let redistribution: Redistribution?
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
    public enum Redistribution: String, Sendable, Hashable, CaseIterable {
        case evaluation
        case `internal`
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
        self.redistribution = wire.redistribution.flatMap(Redistribution.init)
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

extension Database.Redistribution {
    /// `nil` for the generator's `_empty_` case.
    ///
    /// The spec spells "no licence" as `nullable: true` PLUS a `null` member of
    /// the enum, and the generator turns that member into an empty-string case
    /// alongside the three real ones. A `null` on the wire decodes as the absent
    /// Optional rather than as that case, so `_empty_` should be unreachable;
    /// mapping it to "no licence" rather than trapping keeps a surprise from
    /// becoming a crash in a caller's process.
    init?(_ wire: Components.Schemas.Database.RedistributionPayload) {
        switch wire {
        case .evaluation: self = .evaluation
        case ._internal: self = .internal
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
