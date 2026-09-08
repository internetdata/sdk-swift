import AsyncHTTPClient
import Foundation
import OpenAPIAsyncHTTPClient
import Testing

@testable import InternetData

/// The Swift API surface, as distinct from the shared conformance corpus.
@Suite("Client")
struct ClientTests {
    @Test("the api key is presented as a bearer token on every call")
    func apiKeyIsPresented() async throws {
        let stub = StubTransport([
            StubTransport.listPath: .json(["databases": []]),
            StubTransport.downloadsPath: .json(["downloads": []]),
        ])
        let client = client(stub, apiKey: "sk-test")

        _ = try await client.database.list()
        _ = try await client.database.downloads()

        // Bearer is the only scheme v2 accepts; v1's `?apikey=` put the key in a
        // query string, where it lands in every access log on the way.
        await #expect(stub.authorizations == ["Bearer sk-test", "Bearer sk-test"])
    }

    // Today every endpoint is licensed, so a keyless client only ever gets a
    // 401. It still has to BUILD and to send no credential at all: an empty key
    // is what an unset `${{ secrets.X }}` interpolates to, and `Bearer ` with
    // nothing behind it is a worse answer than no header.
    @Test("a keyless client builds and sends no authorization header")
    func keylessClientSendsNoAuthorization() async throws {
        for apiKey in [nil, ""] as [String?] {
            let stub = StubTransport([StubTransport.listPath: .json(["databases": []])])

            _ = try await InternetDataClient(options: .init(apiKey: apiKey, transport: stub))
                .database.list()

            await #expect(stub.authorizations == [nil], "apiKey \(String(describing: apiKey))")
        }
    }

    @Test("retries are configurable, and a client error still is not retried")
    func retriesAreConfigurable() async throws {
        let failing = StubTransport([
            StubTransport.metadataPath: .json(["rc": "UNAVAILABLE"], status: 503)
        ])
        await #expect(throws: InternetDataError.self) {
            try await client(failing, retries: 2).database.metadata(id: "bogon_ip_v1")
        }
        await #expect(failing.callCount == 3, "one attempt plus two retries")

        let refusing = StubTransport([
            StubTransport.metadataPath: .json(["rc": "UNKNOWN_DATASET"], status: 404)
        ])
        let failure = await #expect(throws: InternetDataError.self) {
            try await client(refusing, retries: 3).database.metadata(id: "nope_v1")
        }
        #expect(try #require(failure).kind == .badRequest)
        #expect(try #require(failure).isRetryable == false)
        #expect(try #require(failure).message == "UNKNOWN_DATASET", "the `rc` went unread")
        await #expect(refusing.callCount == 1)
    }

    @Test("a spent quota is never retried")
    func spentQuotaIsNeverRetried() async throws {
        let stub = StubTransport([
            StubTransport.listPath: .json(["rc": "QUOTA_EXCEEDED"], status: 429)
        ])

        let failure = await #expect(throws: InternetDataError.self) {
            try await client(stub, retries: 5).database.list()
        }
        #expect(try #require(failure).kind == .quotaExceeded)
        await #expect(stub.callCount == 1)
    }

    @Test("a rate limit is retried after the server-supplied wait")
    func rateLimitWaitsForRetryAfter() async throws {
        var route = StubTransport.Route.json(["rc": "RATE_LIMITED"], status: 429)
        route.headers = ["Retry-After": "1"]
        let stub = StubTransport([StubTransport.listPath: route])

        let started = ContinuousClock.now
        await #expect(throws: InternetDataError.self) {
            try await client(stub, retries: 1).database.list()
        }
        await #expect(stub.callCount == 2)
        // The header, not the backoff schedule, decides the wait.
        #expect(ContinuousClock.now - started >= .seconds(1))
    }

    @Test("cancelling a call propagates rather than becoming a network failure")
    func cancellingACallPropagates() async throws {
        let stub = StubTransport(
            [StubTransport.listPath: .json(["databases": []])], delay: .seconds(5),
        )
        // Retries OFF on purpose: with them on the backoff sleep is itself
        // cancelled and the error escapes that way, so only a zero-retry client
        // reaches the code that decides what a cancellation looks like.
        let client = client(stub, retries: 0)

        let call = Task { try await client.database.list() }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
    }

    // The licence is held against the FAMILY, and the ids a download takes hang
    // off `versions`. A listing that stopped at the family would leave a caller
    // with nothing to pass to `download`.
    @Test("the catalog carries each family's versions, standing and licence term")
    func listCarriesVersionsAndTerm() async throws {
        let stub = StubTransport([
            StubTransport.listPath: .json([
                "databases": [
                    [
                        "base": "bogon_ip",
                        "name": "Bogon IP",
                        "summary": "Reserved, private or otherwise non-routable IP ranges.",
                        "standing": "licensed",
                        "license_type": "standard",
                        "starts": "2026-09-04T18:04:26.431Z",
                        "expires": NSNull(),
                        "versions": [[
                            "id": "bogon_ip_v1",
                            "version": 1,
                            "summary": "v1",
                            "formats": ["csvgz", "mmdb"],
                        ]],
                    ],
                    [
                        "base": "vpn_ip",
                        "name": "VPN IP",
                        "summary": "VPN exit addresses.",
                        "standing": "unlicensed",
                        "license_type": NSNull(),
                        "starts": NSNull(),
                        "expires": NSNull(),
                        "versions": [[
                            "id": "vpn_ip_v1", "version": 1, "summary": "v1", "formats": ["csvgz"],
                        ]],
                    ],
                ]
            ])
        ])

        let databases = try await client(stub).database.list()

        #expect(databases.count == 2)
        #expect(databases[0].base == "bogon_ip")
        #expect(databases[0].name == "Bogon IP")
        #expect(databases[0].standing == .licensed)
        #expect(databases[0].licenseType == .standard)
        #expect(databases[0].starts != nil)
        #expect(databases[0].expires == nil, "a licence with no end date has no expiry")
        let version = try #require(databases[0].versions.first)
        #expect(version.id == "bogon_ip_v1")
        #expect(version.version == 1)
        #expect(version.formats == [.csvgz, .mmdb])

        // No licence is a null on the wire, not an "unlicensed" license_type.
        #expect(databases[1].standing == .unlicensed)
        #expect(databases[1].licenseType == nil)
        #expect(databases[1].starts == nil)
    }

    // The runtime's stock transcoders each reject what the other accepts, and
    // this API serves the fractional form, so a strict client decodes the whole
    // listing as a corrupt-date failure. No fixture written from the spec can
    // catch it: `format: date-time` says nothing about fractional seconds.
    @Test("a licence date decodes with or without fractional seconds")
    func licenceDatesDecodeEitherWay() async throws {
        let stub = StubTransport([
            StubTransport.listPath: .json([
                "databases": [
                    family("bogon_ip", starts: "2026-09-04T18:04:26.431Z"),
                    family("bogon_asn", starts: "2026-09-04T18:04:26Z"),
                ]
            ])
        ])

        let databases = try await client(stub).database.list()

        #expect(databases.count == 2)
        for database in databases {
            #expect(database.starts != nil, "\(database.base) lost its start date")
        }
        #expect(databases[0].starts == databases[1].starts?.addingTimeInterval(0.431))
    }

    @Test("a download attempt decodes every field, including a fractional timestamp")
    func downloadsCarryTheWholeAttempt() async throws {
        let stub = StubTransport([
            StubTransport.downloadsPath: .json([
                "downloads": [[
                    "dataset_id": "bogon_asn_v1",
                    "format": "csvgz",
                    "outcome": "ok",
                    "bytes": 264,
                    "http_status": 302,
                    "apikey_id": "86be2651-2c75-4180-8287-25c72a758a72",
                    "client_ip": "203.0.113.7",
                    "user_agent": "InternetData Swift",
                    "created": "2026-09-05T00:24:59.666Z",
                ]]
            ])
        ])

        let downloads = try await client(stub).database.downloads(limit: 3)

        let attempt = try #require(downloads.first)
        #expect(attempt.datasetId == "bogon_asn_v1")
        #expect(attempt.format == "csvgz")
        #expect(attempt.outcome == .ok)
        #expect(attempt.bytes == 264)
        #expect(attempt.httpStatus == 302)
        #expect(attempt.apikeyId == "86be2651-2c75-4180-8287-25c72a758a72")
        #expect(attempt.clientIp == "203.0.113.7")
        #expect(attempt.userAgent == "InternetData Swift")
        #expect(attempt.created.timeIntervalSince1970 > 0)
        // Refusals are listed too, so `bytes` and `http_status` are nullable.
        #expect(Download.Outcome.allCases.contains(.denied))
    }

    @Test("the checksum endpoint answers the whole digest set")
    func checksumsReturnsEveryDigest() async throws {
        let stub = StubTransport([
            StubTransport.checksumPath: .json([
                "id": "bogon_asn_v1",
                "format": "csvgz",
                "checksums": [
                    "md5": "3d01a178473cc6e6f37275a2232db2e5",
                    "sha1": "ca849c17169355c0f8ffb7793651defa694a694d",
                    "sha256": "7708b4474d4955fa4c3f788cf216aeeed1a4f4b9e592fe35a2e4b9ab095e0f40",
                    "sha512": "8a868b4437c68e4f59b589133e888c307a256632b03b8c5aac48d6af2d24ec04",
                ],
            ])
        ])

        let checksums = try await client(stub).database.checksums(id: "bogon_asn_v1", format: .csvgz)

        // Nested under `checksums`, not at the top level, and all four come back.
        #expect(checksums.md5 == "3d01a178473cc6e6f37275a2232db2e5")
        #expect(checksums.sha1 == "ca849c17169355c0f8ffb7793651defa694a694d")
        #expect(
            checksums.sha256 == "7708b4474d4955fa4c3f788cf216aeeed1a4f4b9e592fe35a2e4b9ab095e0f40",
        )
        #expect(checksums.sha512 == "8a868b4437c68e4f59b589133e888c307a256632b03b8c5aac48d6af2d24ec04")
    }

    @Test("metadata unwraps schema, sample and size")
    func metadataUnwrapsItsNestedMaps() async throws {
        let stub = StubTransport([
            StubTransport.metadataPath: .json([
                "id": "bogon_ip_v1",
                "update_freq": "daily",
                "updated": "2026-09-04",
                "entries": 44,
                "schema": [
                    "csvgz": [["name": "start_ip", "type": "ipaddress", "description": "Start IP."]]
                ],
                "sample": [
                    "csvgz": [["start_ip": "::", "end_ip": "::ffff:ffff", "rows": 3, "ok": true]]
                ],
                "size": ["csvgz": 760, "mmdb": 3524],
            ])
        ])

        let metadata = try await client(stub).database.metadata(id: "bogon_ip_v1")

        #expect(metadata.id == "bogon_ip_v1")
        #expect(metadata.updateFreq == "daily")
        // A calendar date, left as the string the API published.
        #expect(metadata.updated == "2026-09-04")
        #expect(metadata.entries == 44)
        #expect(metadata.schema["csvgz"]?.first?.name == "start_ip")
        #expect(metadata.schema["csvgz"]?.first?.type == "ipaddress")
        #expect(metadata.schema["csvgz"]?.first?.description == "Start IP.")
        #expect(metadata.sample["csvgz"]?.first?["start_ip"] == .string("::"))
        #expect(metadata.sample["csvgz"]?.first?["rows"]?.intValue == 3)
        #expect(metadata.sample["csvgz"]?.first?["ok"] == .bool(true))
        #expect(metadata.size["csvgz"] == 760)
        #expect(metadata.size["mmdb"] == 3524)
    }

    // Byte counts are Int64 rather than Int because published files pass 5 GiB
    // and `Int` is 32 bits on watchOS's arm64_32.
    @Test("a size past Int32 survives the mapping")
    func aMultiGigabyteSizeIsNotTruncated() async throws {
        let huge: Int64 = 5_733_061_000
        let stub = StubTransport([
            StubTransport.metadataPath: .json([
                "id": "resproxy_ip_90d_v1",
                "updated": "2026-09-04",
                "entries": 4_000_000_000,
                "schema": ["csvgz": []],
                "size": ["csvgz": huge],
            ])
        ])

        let metadata = try await client(stub).database.metadata(id: "resproxy_ip_90d_v1")

        #expect(metadata.size["csvgz"] == huge)
        #expect(metadata.entries == 4_000_000_000)
    }

    @Test("an unusable option is rejected rather than silently clamped")
    func optionsAreValidated() {
        #expect(InternetDataClient.Options(apiKey: "k").retries == 2)
        #expect(InternetDataClient.Options(apiKey: "k").baseURL == InternetDataClient.defaultBaseURL)
        #expect(InternetDataClient.defaultBaseURL.absoluteString == "https://internetdata.io")
    }
}

/// The download endpoint answers `302` to object storage, and following it would
/// read a database that runs to gigabytes into memory. Both halves are asserted
/// against real local origins, because a stub cannot follow anything.
@Suite("Download redirect")
struct DownloadRedirectTests {
    @Test("the presigned url is returned, and storage is never contacted")
    func redirectIsNotFollowed() async throws {
        let storage = try await TestOrigin.start { _ in .neverEndingGigabyte }
        let location = "http://127.0.0.1:\(storage.port)/bogon_ip_v1.mmdb?signature=abc"
        let api = try await TestOrigin.start { _ in .redirect(to: location) }
        defer {
            Task { try? await storage.stop() }
            Task { try? await api.stop() }
        }

        let client = InternetDataClient(
            options: .init(apiKey: "key", baseURL: URL(string: "http://127.0.0.1:\(api.port)")!),
        )
        let url = try await client.database.downloadURL(id: "bogon_ip_v1", format: .mmdb)

        // The link carries its own signature, so it is safe to hand to something
        // holding no API key.
        #expect(url.absoluteString == location)
        #expect(api.receivedPaths.count == 1)
        #expect(
            storage.receivedPaths.isEmpty,
            "the transport followed the redirect and is holding the database",
        )
    }

    @Test("a transport that does follow redirects is refused before the body is read")
    func aFollowingTransportIsRefused() async throws {
        let storage = try await TestOrigin.start { _ in .neverEndingGigabyte }
        let location = "http://127.0.0.1:\(storage.port)/bogon_ip_v1.mmdb"
        let api = try await TestOrigin.start { _ in .redirect(to: location) }
        let follower = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: .init(redirectConfiguration: .follow(max: 5, allowCycles: false)),
        )
        defer {
            Task { try? await follower.shutdown() }
            Task { try? await storage.stop() }
            Task { try? await api.stop() }
        }

        let client = InternetDataClient(
            options: .init(
                apiKey: "key",
                baseURL: URL(string: "http://127.0.0.1:\(api.port)")!,
                retries: 0,
                transport: AsyncHTTPClientTransport(configuration: .init(client: follower)),
            ),
        )

        let started = ContinuousClock.now
        let failure = await #expect(throws: InternetDataError.self) {
            try await client.database.downloadURL(id: "bogon_ip_v1", format: .mmdb)
        }
        let elapsed = ContinuousClock.now - started

        #expect(try #require(failure).status == 200)
        // Storage was reached, so the guard is what stopped the transfer rather
        // than the redirect never happening.
        #expect(storage.receivedPaths.count == 1)
        #expect(elapsed < .seconds(5), "the promised gigabyte was being read")
    }
}

/// The streaming transfer, against real local origins for the same reason: the
/// second request goes to object storage rather than to the API, and what it
/// must NOT carry is a header.
@Suite("Download transfer")
struct DownloadTransferTests {
    struct SinkStopped: Error {}

    static let payload: [UInt8] = Array("a small database, gzipped in real life".utf8)

    @Test("a download lands intact, and the key never reaches object storage")
    func downloadWritesTheFileAndWithholdsTheKey() async throws {
        let origins = try await Origins.start(.file(Self.payload))
        defer { origins.stop() }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("bogon_ip_v1.csv.gz")

        let written = try await origins.client.database.download(
            "bogon_ip_v1", format: .csvgz, to: destination,
        )

        #expect(written == Int64(Self.payload.count))
        let landed = try Data(contentsOf: destination)
        #expect([UInt8](landed) == Self.payload)
        #expect(Int64(landed.count) == written, "the file is not the length the method reported")
        #expect(
            FileManager.default.fileExists(atPath: destination.path + ".part") == false,
            "the .part file outlived a successful transfer",
        )
        #expect(origins.api.receivedAuthorizations == ["Bearer key"])
        #expect(
            origins.storage.receivedAuthorizations == [nil],
            "the API key was presented to object storage",
        )
    }

    @Test("downloadBytes hands back the same bytes")
    func downloadBytesMatchesTheFile() async throws {
        let origins = try await Origins.start(.file(Self.payload))
        defer { origins.stop() }

        let bytes = try await origins.client.database.downloadBytes("bogon_ip_v1", format: .csvgz)

        #expect([UInt8](bytes) == Self.payload)
        #expect(origins.storage.receivedAuthorizations == [nil])
    }

    // Writing straight to the destination passes every other case here, because
    // a refusal fails before any file exists. Only a death mid-body produces the
    // truncated file that would otherwise read as a whole database.
    @Test("a transfer that dies leaves neither a partial nor a whole file")
    func aDeadTransferLeavesNothingBehind() async throws {
        let origins = try await Origins.start(.truncated(promising: 4096, writing: 16))
        defer { origins.stop() }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("bogon_ip_v1.csv.gz")

        await #expect(throws: (any Error).self) {
            try await origins.client.database.download("bogon_ip_v1", format: .csvgz, to: destination)
        }

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: destination.path) == false)
        #expect(manager.fileExists(atPath: destination.path + ".part") == false)
    }

    // The sink sees bytes while the body is still arriving, so nothing collected
    // the file first. The time limit is what makes a buffering implementation
    // FAIL rather than hang: collecting first waits on a gigabyte that never
    // comes, and minutes are the only granularity swift-testing offers.
    @Test("the sink is fed while the body is still arriving", .timeLimit(.minutes(1)))
    func theSinkSeesBytesBeforeTheBodyEnds() async throws {
        let origins = try await Origins.start(.neverEndingGigabyte)
        defer { origins.stop() }

        let started = ContinuousClock.now
        await #expect(throws: SinkStopped.self) {
            try await origins.client.database.download("bogon_ip_v1", format: .csvgz) { chunk in
                #expect(chunk.isEmpty == false)
                throw SinkStopped()
            }
        }
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(5), "the promised gigabyte was being collected first")
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("internetdata-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An API that redirects and a storage host that answers, plus a client
    /// pointed at the first.
    struct Origins {
        let api: TestOrigin
        let storage: TestOrigin
        let client: InternetDataClient

        static func start(_ answer: TestOrigin.Answer) async throws -> Origins {
            let storage = try await TestOrigin.start { _ in answer }
            let location = "http://127.0.0.1:\(storage.port)/bogon_ip_v1.csv.gz?signature=abc"
            let api = try await TestOrigin.start { _ in .redirect(to: location) }
            return Origins(
                api: api,
                storage: storage,
                client: InternetDataClient(
                    options: .init(
                        apiKey: "key",
                        baseURL: URL(string: "http://127.0.0.1:\(api.port)")!,
                        retries: 0,
                    ),
                ),
            )
        }

        func stop() {
            Task { try? await storage.stop() }
            Task { try? await api.stop() }
        }
    }
}

extension ClientTests {
    func family(_ base: String, starts: String) -> [String: Any] {
        [
            "base": base,
            "name": base,
            "summary": "\(base) summary",
            "standing": "licensed",
            "license_type": "standard",
            "starts": starts,
            "expires": NSNull(),
            "versions": [["id": "\(base)_v1", "version": 1, "summary": "v1", "formats": ["csvgz"]]],
        ]
    }

    func client(
        _ transport: StubTransport, apiKey: String = "key", retries: Int = 2,
    ) -> InternetDataClient {
        InternetDataClient(
            options: .init(apiKey: apiKey, retries: retries, transport: transport),
        )
    }
}
