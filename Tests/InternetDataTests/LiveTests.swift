import Foundation
import Testing

@testable import InternetData

/// Real requests against a real deployment, skipped unless `INTERNETDATA_LIVE=1`
/// so the ordinary suite stays offline and costs no quota.
///
///     INTERNETDATA_API_KEY=... INTERNETDATA_LIVE=1 ./scripts/test.sh --filter Live
///
/// The integration package is what exercises the PUBLISHED artifact; this is the
/// short loop while the library is being changed. It exists for one assertion a
/// fixture cannot make honestly: the spec says `format: date-time` and nothing
/// about fractional seconds, so only a served answer proves which transcoder is
/// needed.
@Suite("Live", .enabled(if: ProcessInfo.processInfo.environment["INTERNETDATA_LIVE"] == "1"))
struct LiveTests {
    static let apiKey = ProcessInfo.processInfo.environment["INTERNETDATA_API_KEY"] ?? ""
    static let baseURL =
        (ProcessInfo.processInfo.environment["INTERNETDATA_BASE_URL"])
        .flatMap(URL.init(string:)) ?? InternetDataClient.defaultBaseURL

    static var client: InternetDataClient {
        InternetDataClient(options: .init(apiKey: apiKey, baseURL: baseURL))
    }

    @Test("the catalog decodes, licence dates and all")
    func catalogDecodes() async throws {
        let databases = try await Self.client.database.list()

        #expect(databases.isEmpty == false, "the catalog is empty")
        for database in databases {
            #expect(database.base.isEmpty == false)
            #expect(database.versions.isEmpty == false, "\(database.base) carries no versions")
            for version in database.versions {
                #expect(version.id.isEmpty == false)
                #expect(version.formats.isEmpty == false)
            }
            guard database.standing == .licensed else {
                #expect(database.licenseType == nil, "\(database.base) is not licensed")
                continue
            }
            // The one thing no fixture can prove: these arrive as
            // `2026-09-04T18:04:26.431Z`, which the runtime's stock `.iso8601`
            // transcoder rejects outright.
            #expect(database.starts != nil, "\(database.base) lost its licence start date")
            #expect(database.licenseType != nil, "\(database.base) is licensed for nothing")
        }
    }

    @Test("metadata and checksums answer for a licensed database")
    func metadataAndChecksums() async throws {
        let client = Self.client
        let licensed = try await client.database.list().filter { $0.standing == .licensed }
        let version = try #require(
            licensed.first?.versions.last, "this key licenses nothing to read",
        )
        let format = try #require(version.formats.first)

        let metadata = try await client.database.metadata(id: version.id)
        #expect(metadata.id == version.id)
        #expect(metadata.entries > 0)
        #expect(try #require(metadata.size[format.rawValue]) > 0)
        #expect(metadata.updated.count == 10, "updated is a YYYY-MM-DD calendar date")

        let checksums = try await client.database.checksums(id: version.id, format: format)
        #expect(checksums.sha256.count == 64, "checksums must unwrap past the envelope")
    }

    @Test("a download attempt history decodes")
    func downloadsDecode() async throws {
        let attempts = try await Self.client.database.downloads(limit: 5)

        for attempt in attempts {
            #expect(attempt.datasetId.isEmpty == false)
            #expect(attempt.created.timeIntervalSince1970 > 0)
        }
    }
}
