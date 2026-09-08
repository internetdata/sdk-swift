import Crypto
import Foundation
import InternetData
import Testing

/// The whole API, against staging, through the package a consumer resolves.
///
/// Every id is DISCOVERED from `list` rather than written down here. That keeps
/// the suite honest when the CI organization's licences change, and it keeps the
/// names of anything private out of a public repository.
///
/// The transfer is budgeted before it starts: `metadata` publishes a size per
/// format, and the smallest licensed file is checked against the ceiling below
/// FIRST, so a licence change can never quietly pull gigabytes through CI.
@Suite("Staging database")
struct DatabaseTests {
    /// 8 MiB. The licensed files are measured in hundreds of bytes, so three
    /// orders of magnitude of headroom: tripping this means the suite is
    /// pointed somewhere unintended, which is exactly when a transfer must not
    /// go ahead. Published databases reach 5 GiB.
    static let ceiling: Int64 = 8 * 1024 * 1024

    @Test("the catalog answers the family shape, and the key reached the wire", Credential.needsKey)
    func catalogAnswersTheFamilyShape() async throws {
        let transport = RecordingTransport()
        let databases = try await stagingClient(transport: transport).database.list()

        #expect(databases.isEmpty == false, "the catalog is empty")
        for database in databases {
            #expect(database.base.isEmpty == false)
            #expect(database.name.isEmpty == false)
            // A licence covers the FAMILY, and these are the ids the download,
            // checksum and metadata methods take. A listing that stopped at the
            // family would leave a caller with nothing to pass to `download`.
            #expect(database.versions.isEmpty == false, "\(database.base) carries no versions")
            for version in database.versions {
                #expect(version.id.isEmpty == false, "\(database.base) has a version with no id")
                #expect(version.version > 0)
                #expect(version.formats.isEmpty == false, "\(version.id) is built in no format")
            }
            guard database.standing == .licensed else {
                #expect(
                    database.licenseType == nil,
                    "\(database.base) is not licensed but carries a license type",
                )
                continue
            }
            // Served as `2026-09-04T18:04:26.431Z`. The runtime's stock
            // `.iso8601` transcoder rejects fractional seconds outright, so this
            // is the assertion no fixture can make: the spec says only
            // `format: date-time`.
            #expect(database.starts != nil, "\(database.base) lost its licence start date")
            #expect(database.licenseType != nil, "\(database.base) is licensed for nothing")
        }

        // Without this the comparisons above are vacuous: an unauthenticated
        // request is a 401, but a request that merely LOOKED authenticated is
        // indistinguishable from a real one until you check. The emptiness check
        // is not redundant - `allSatisfy` is TRUE on no requests at all, which is
        // the one shape that would let this pass having proved nothing.
        let facts = await transport.facts
        #expect(facts.isEmpty == false, "no request was recorded, so nothing was proved")
        #expect(facts.allSatisfy { $0.carriedKey }, "the staging key never reached the wire")
    }

    @Test("a database the organization does not license is refused cleanly", Credential.needsKey)
    func anUnlicensedDatabaseIsRefused() async throws {
        let transport = RecordingTransport()
        let client = stagingClient(transport: transport)
        let catalog = try await client.database.list()
        let unlicensed = try #require(
            catalog.first(where: { $0.standing != .licensed })?.versions.first,
            "this organization licenses the whole catalog, so nothing can be refused",
        )
        let format = try #require(unlicensed.formats.first)
        let before = await transport.facts.count

        let failure = await #expect(throws: InternetDataError.self) {
            try await client.database.downloadURL(id: unlicensed.id, format: format)
        }

        let error = try #require(failure)
        #expect(error.kind == .forbidden)
        #expect(error.status == 403)
        #expect(error.isRetryable == false, "a licence refusal is not worth retrying")
        // The API says which refusal this is, in `rc`. Falling back to the
        // status means the client never read the envelope.
        #expect(
            error.message.hasPrefix("request failed with status") == false,
            "the message is the client fallback, so the response body went unread",
        )
        #expect(await transport.facts.count == before + 1, "a 4xx must not be retried")
    }

    @Test("download streams a real database to disk intact", Credential.needsKey)
    func downloadStreamsTheDatabaseIntact() async throws {
        let transfer = try await Transfers.shared.transfer()

        #expect(transfer.written > 0, "nothing was transferred")
        let landed = try Data(contentsOf: transfer.file)
        #expect(Int64(landed.count) == transfer.written, "the file is not the length reported")
        #expect(Int64(landed.count) == transfer.published, "the file is not the published size")
        #expect(
            FileManager.default.fileExists(atPath: transfer.file.path + ".part") == false,
            "the .part file outlived a successful transfer",
        )
        if transfer.format == .csvgz {
            #expect([UInt8](landed.prefix(2)) == [0x1f, 0x8b], "the payload is not gzip")
        }

        #expect(transfer.checksums.sha256.count == 64, "checksums must unwrap past the envelope")
        #expect(sha256(landed) == transfer.checksums.sha256, "the bytes are not the published file")

        // The presigned URL authorizes itself, so the second request must carry
        // no credential at all.
        let toStorage = transfer.facts.filter { $0.origin != staging.absoluteString }
        #expect(
            toStorage.isEmpty == false, "object storage was never reached, so no 302 was followed",
        )
        for fact in toStorage {
            #expect(fact.carriedKey == false, "the API key was sent to object storage")
        }
    }

    @Test("downloadBytes agrees with the streamed copy", Credential.needsKey)
    func downloadBytesAgreesWithTheFile() async throws {
        let transfer = try await Transfers.shared.transfer()

        let bytes = try await transfer.client.database.downloadBytes(transfer.id, format: transfer.format)

        #expect(Int64(bytes.count) == transfer.written, "the in-memory copy is a different length")
        #expect(sha256(bytes) == transfer.checksums.sha256, "the in-memory copy is not the file")
    }

    /// The v2 answer is a `302`, so a caller can be handed a link that carries
    /// its own signature and needs no API key. That is the whole reason this
    /// method can exist at all.
    @Test("downloadURL hands back a credential-free link on another host", Credential.needsKey)
    func downloadURLIsCredentialFree() async throws {
        let transfer = try await Transfers.shared.transfer()

        let url = try await transfer.client.database.downloadURL(id: transfer.id, format: transfer.format)

        #expect(
            url.absoluteString.hasPrefix(staging.absoluteString) == false,
            "the link points back at the API rather than at object storage",
        )
        #expect(url.query?.isEmpty == false, "a presigned link carries its signature in the query")
        #expect(
            url.absoluteString.contains(Credential.key) == false,
            "the API key is embedded in the download link",
        )
    }

    @Test("the download history lists the attempt that just ran", Credential.needsKey)
    func downloadsListTheAttempt() async throws {
        let transfer = try await Transfers.shared.transfer()

        let attempts = try await transfer.client.database.downloads(limit: 50)

        #expect(attempts.isEmpty == false, "a transfer just ran, so the history cannot be empty")
        let mine = attempts.filter { $0.datasetId == transfer.id }
        #expect(mine.isEmpty == false, "the transfer that just ran is not in the history")
        for attempt in attempts {
            #expect(attempt.created.timeIntervalSince1970 > 0, "an attempt lost its timestamp")
        }
        // Newest first, and refusals are listed too, which is what answers
        // "it stopped working".
        #expect(attempts == attempts.sorted { $0.created > $1.created }, "not newest first")
    }
}

/// One transfer for the whole run, so five tests share a download rather than
/// pulling the file once each. Tests run in parallel, so the memo holds the
/// TASK: two readers arriving together wait on one transfer instead of starting
/// two.
actor Transfers {
    static let shared = Transfers()

    private var pending: Task<Transfer, any Error>?

    func transfer() async throws -> Transfer {
        if let pending {
            return try await pending.value
        }
        let task = Task { try await downloadOnce() }
        pending = task
        return try await task.value
    }
}

struct Transfer: Sendable {
    let client: InternetDataClient
    let id: String
    let format: DatabaseFormat
    let file: URL
    let written: Int64
    /// What `metadata` said the file weighs, checked against what landed.
    let published: Int64
    let checksums: DatabaseChecksums
    let facts: [RecordingTransport.Fact]
}

private func downloadOnce() async throws -> Transfer {
    let transport = RecordingTransport()
    let client = stagingClient(transport: transport)

    let (id, format, published) = try await smallestLicensedFile(client)
    // An interpolated literal is a `Comment`; a concatenation is a `String` and
    // will not compile as one.
    let ceiling = DatabaseTests.ceiling
    try #require(
        published > 0 && published <= ceiling,
        "\(id).\(format.rawValue) is \(published) bytes, past the \(ceiling) byte ceiling",
    )

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("internetdata-integration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("\(id).\(format.rawValue)")

    let written = try await client.database.download(id, format: format, to: file)
    // Read after the transfer, so a rebuild between the two calls shows up as a
    // digest mismatch rather than passing against a digest of nothing.
    let checksums = try await client.database.checksums(id: id, format: format)
    print("\(id).\(format.rawValue): \(written) bytes, metadata says \(published)")

    return Transfer(
        client: client,
        id: id,
        format: format,
        file: file,
        written: written,
        published: published,
        checksums: checksums,
        facts: await transport.facts,
    )
}

/// The smallest file this organization is licensed for, discovered rather than
/// written down.
///
/// The licences a CI organization holds are not this repository's business, and
/// naming one here would both rot and publish it. Picking the smallest is what
/// keeps the run cheap; the ceiling is what keeps it safe when the smallest is
/// not small.
private func smallestLicensedFile(
    _ client: InternetDataClient,
) async throws -> (id: String, format: DatabaseFormat, bytes: Int64) {
    let licensed = try await client.database.list().filter { $0.standing == .licensed }
    try #require(licensed.isEmpty == false, "this organization licenses nothing to download")

    var candidates: [(id: String, format: DatabaseFormat, bytes: Int64)] = []
    for database in licensed {
        for version in database.versions {
            let metadata = try await client.database.metadata(id: version.id)
            #expect(metadata.id == version.id)
            #expect(metadata.entries > 0, "\(version.id) publishes no rows")
            for format in version.formats {
                guard let bytes = metadata.size[format.rawValue], bytes > 0 else {
                    Issue.record("\(version.id) is built in \(format.rawValue) with no size")
                    continue
                }
                candidates.append((version.id, format, bytes))
            }
        }
    }
    return try #require(
        candidates.min(by: { $0.bytes < $1.bytes }),
        "no licensed database publishes a size to budget against",
    )
}

private func sha256(_ bytes: some DataProtocol) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
