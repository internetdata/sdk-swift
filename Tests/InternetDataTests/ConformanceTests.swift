import Foundation
import Testing

@testable import InternetData

/// Asserts the shared conformance corpus that every InternetData SDK asserts.
@Suite("Conformance")
struct ConformanceTests {
    let corpus = Corpus.shared

    /// The corpus is worth nothing if a rename quietly empties it.
    @Test("the corpus carries every fixture family")
    func corpusIsPopulated() {
        #expect(corpus.errors.isEmpty == false)
        #expect(corpus.visibility.clientRules.isEmpty == false)
    }

    // Classification is by RANGE, so 404 (`UNKNOWN_DATASET`, `NOT_FOUND`,
    // `DB_NOT_FOUND`) is a client error and is never retried. Mapping
    // 400/401/403/429 and letting the rest fall through to a retryable
    // `server_error` is the easy mistake, and three of four VPNDetection SDKs
    // shipped with it.
    @Test("every documented refusal maps to its kind, and only 5xx-ish is retryable")
    func errorsAreClassifiedByRange() async throws {
        for testCase in corpus.errors {
            let route = StubTransport.Route(
                status: testCase.status, body: testCase.body.encoded, headers: testCase.headers,
            )
            // No retries, so a retryable failure surfaces rather than looping.
            let stub = StubTransport([StubTransport.metadataPath: route])
            let client = testClient(stub, retries: 0)

            let failure = await #expect(throws: InternetDataError.self) {
                try await client.metadata(id: "bogon_ip_v1")
            }
            guard let error = failure else {
                Issue.record("\(testCase.name): no InternetDataError was thrown")
                continue
            }
            #expect(error.kind.rawValue == testCase.expect.kind, "\(testCase.name)")
            #expect(error.isRetryable == testCase.expect.retryable, "\(testCase.name): retryable")
            #expect(error.status == testCase.status, "\(testCase.name): status")
            if let message = testCase.expect.message {
                #expect(error.message == message, "\(testCase.name): message")
            }
            if let seconds = testCase.expect.retryAfterSeconds {
                #expect(error.retryAfter == .seconds(seconds), "\(testCase.name): retryAfter")
            }
            await #expect(
                stub.callCount == 1, "\(testCase.name): a client error must not be retried",
            )
        }
    }

    // A retryable failure is the other half of the same rule: pinning only that
    // nothing is retried would pass on a client that never retries at all.
    @Test("a retryable refusal really is retried")
    func retryableErrorsAreRetried() async throws {
        let retryable = corpus.errors.filter { $0.expect.retryable }
        #expect(retryable.isEmpty == false, "the corpus pins no retryable failure")

        for testCase in retryable {
            let route = StubTransport.Route(
                status: testCase.status, body: testCase.body.encoded, headers: testCase.headers,
            )
            let stub = StubTransport([StubTransport.metadataPath: route])

            await #expect(throws: InternetDataError.self) {
                try await testClient(stub, retries: 1).metadata(id: "bogon_ip_v1")
            }
            await #expect(stub.callCount == 2, "\(testCase.name): one attempt plus one retry")
        }
    }

    @Test("the vocabularies the API answers with are the ones the library exposes")
    func vocabulariesMatchTheCorpus() {
        #expect(Set(Database.Standing.allCases.map(\.rawValue)) == Set(corpus.standings))
        #expect(
            Set(Database.Redistribution.allCases.map(\.rawValue)) == Set(corpus.redistribution),
        )
        #expect(Set(DatabaseFormat.allCases.map(\.rawValue)) == Set(corpus.formats))
    }

    /// The visibility contract, which is a rule about what an SDK must NOT do.
    ///
    /// A private family is one built for a single customer. The server leaves it
    /// out of a listing for anyone else rather than showing it as `unlicensed`,
    /// so `list` is the whole of what a key may know about, and it is not the
    /// same list for everyone. The corpus NAMES the rules rather than giving
    /// example families, because it ships inside public repositories.
    @Test("every visibility rule the corpus names has an assertion behind it")
    func everyVisibilityRuleIsAsserted() {
        // A `Comment` is a literal, so the corpus's own explanation is recorded
        // rather than interpolated into the message.
        if Set(corpus.visibility.clientRules) != Set(Self.visibilityRules) {
            Issue.record(
                Comment(
                    rawValue: "a visibility rule has no assertion behind it."
                        + " corpus: \(corpus.visibility.clientRules)."
                        + " asserted: \(Self.visibilityRules)."
                        + " why: \(corpus.visibility.why)",
                ),
            )
        }
    }

    static let visibilityRules = [
        "listing-is-returned-as-served",
        "no-catalog-is-compiled-into-the-client",
        "a-listing-is-never-reused-across-clients",
    ]

    /// listing-is-returned-as-served.
    @Test("a listing is handed back exactly as served, in order and unpadded")
    func listingIsReturnedAsServed() async throws {
        let served = ["bogon_asn", "bogon_ip"]
        let stub = StubTransport([
            StubTransport.listPath: .json([
                "databases": served.map { family($0, standing: "licensed") }
            ])
        ])

        let databases = try await testClient(stub).list()

        #expect(databases.map(\.base) == served, "the listing was reordered, padded or dropped")
    }

    /// no-catalog-is-compiled-into-the-client. An organization that licenses
    /// nothing and may see nothing gets an empty list, not a built-in catalog.
    @Test("nothing is synthesized when the server lists nothing")
    func noCatalogIsCompiledIntoTheClient() async throws {
        let stub = StubTransport([StubTransport.listPath: .json(["databases": []])])

        let databases = try await testClient(stub).list()

        #expect(databases.isEmpty, "the client invented a catalog the server did not serve")
    }

    /// a-listing-is-never-reused-across-clients. Two keys can hold different
    /// licences, so a catalog cached against one is not a catalog for another.
    @Test("a listing is never cached, within a client or across two")
    func listingIsNeverReusedAcrossClients() async throws {
        let stub = StubTransport([
            StubTransport.listPath: .json(["databases": [family("bogon_ip", standing: "licensed")]])
        ])

        let first = testClient(stub, apiKey: "key-a")
        _ = try await first.list()
        _ = try await first.list()
        _ = try await testClient(stub, apiKey: "key-b").list()

        await #expect(stub.callCount == 3, "a listing was served from a cache")
        await #expect(stub.authorizations == ["Bearer key-a", "Bearer key-a", "Bearer key-b"])
    }
}

extension ConformanceTests {
    func testClient(
        _ transport: StubTransport, apiKey: String = "key", retries: Int = 2,
    ) -> InternetDataClient {
        InternetDataClient(
            options: .init(apiKey: apiKey, retries: retries, transport: transport),
        )
    }

    func family(_ base: String, standing: String) -> [String: Any] {
        [
            "base": base,
            "name": base,
            "summary": "\(base) summary",
            "standing": standing,
            "redistribution": standing == "licensed" ? "internal" : NSNull(),
            "starts": standing == "licensed" ? "2026-09-04T18:04:26.431Z" : NSNull(),
            "expires": NSNull(),
            "versions": [[
                "id": "\(base)_v1", "version": 1, "summary": "v1", "formats": ["csvgz"],
            ]],
        ]
    }
}
