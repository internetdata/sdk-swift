import Foundation
import Testing

@testable import InternetData

/// Asserts the shared conformance corpus that every InternetData SDK asserts.
///
/// The corpus is generated into `testdata/` and is identical across languages, so
/// a behavior that drifts here fails here rather than surfacing as two client
/// libraries quietly disagreeing about the same address.
@Suite("Conformance")
struct ConformanceTests {
    let corpus = Corpus.shared

    // Held at their public type until the next major: these eight are `Bool`, so
    // an answer without one reads false, where every other absent member reads
    // absent. The one list the check below makes that exception for.
    static let heldFlags = [
        "is_bot", "is_carrier", "is_satellite", "is_ssh", "is_smtp", "is_web", "is_dns_resolver",
        "is_bittorrent",
    ]

    // The AS's type is held the same way: a `String`, so an answer without one reads it empty.
    static let heldInAsn = ["type"]

    /// The corpus is worth nothing if a rename quietly empties it.
    @Test("the corpus carries every fixture family")
    func corpusIsPopulated() {
        #expect(corpus.errors.isEmpty == false)
        #expect(corpus.isBogon.isEmpty == false)
        #expect(corpus.ipv4Mapped.isEmpty == false)
        #expect(corpus.lookup.isEmpty == false)
        #expect(corpus.batch.isEmpty == false)
        #expect(corpus.visibility.clientRules.isEmpty == false)
    }

    @Test("isBogon matches the canonical ranges")
    func isBogonMatchesTheCanonicalRanges() {
        for testCase in corpus.isBogon {
            #expect(
                InternetData.isBogon(testCase.ip) == testCase.expect,
                "\(testCase.ip) (\(testCase.why))",
            )
        }
    }

    // A server listening on :: sees every IPv4 visitor as ::ffff:a.b.c.d. Read
    // whole that is inside ::ffff:0:0/96, so an SDK that did not unmap answered
    // each one locally as a bogon.
    @Test("an IPv4-mapped address is the IPv4 address it carries")
    func ipv4MappedAddressIsTheAddressItCarries() async throws {
        for testCase in corpus.ipv4Mapped {
            let label = "\(testCase.ip) (\(testCase.why))"
            #expect(InternetData.isBogon(testCase.ip) == testCase.expect, "\(label): isBogon")

            let stub = StubTransport.answering(testCase.carries)
            let client = testClient(stub, retries: 0)
            let result = try await client.lookup(testCase.ip)
            #expect(result.ip == testCase.carries, "\(label): the answer names the address it carries")
            #expect(result.isBogon == testCase.expect, "\(label): answered locally exactly when a bogon")
            if testCase.expect {
                await #expect(stub.callCount == 0, "\(label): a bogon must not reach the network")
            } else {
                await #expect(stub.calls == [testCase.carries], "\(label): sent as \(testCase.carries)")
                _ = try await client.lookup(testCase.carries)
                await #expect(stub.callCount == 1, "\(label): \(testCase.carries) is then a cache hit")
            }

            // The mapped form alone: asked beside its plain form, a batch that sent
            // the address as given would still have been answered for the plain one.
            let batchStub = StubTransport.answering(testCase.carries)
            let results = try await testClient(batchStub, retries: 0).lookupBatch([testCase.ip])
            #expect(results.keys == [testCase.ip], "\(label): keyed as passed")
            #expect(try results[testCase.ip]?.get().ip == testCase.carries, "\(label): batch answer")
            let sent = await batchStub.batchIps
            #expect(sent == (testCase.expect ? [] : [testCase.carries]), "\(label): the batch body")
        }
    }

    // The API serves `is_bogon` itself, so the local answer is the one it would
    // serve a paid plan, with the address filled in.
    @Test("a bogon is answered locally in the shape the API answers one")
    func bogonIsAnsweredLocallyInTheApisShape() async throws {
        let stub = StubTransport()
        let client = testClient(stub)

        let result = try await client.lookup("10.0.0.1")
        let wire = result.wire

        var answer = corpus.bogonResponse.answer.objectValue
        answer["ip"] = .string("10.0.0.1")
        #expect(wire == JSONValue.object(answer).normalized)
        #expect(result.isBogon)
        for name in corpus.bogonResponse.flagsFalse {
            #expect(wire[name] == .bool(false), "\(name) must be present and false")
        }
        for name in corpus.bogonResponse.emptyObjects {
            #expect(wire[name] == .object([:]), "\(name) must be present and empty")
        }
        for name in corpus.bogonResponse.emptyLists {
            #expect(wire[name] == .array([]), "\(name) must be present and empty")
        }
        await #expect(stub.callCount == 0, "a bogon must not reach the network")
    }

    @Test("every answer keeps absent apart from false, a shared object's members included")
    func lookupPreservesAbsentVersusFalse() async throws {
        for testCase in corpus.lookup {
            let label = testCase.name
            guard let (route, call) = Self.route(testCase) else {
                Issue.record("\(label): no call reads \(testCase.call) of \(testCase.target)")
                continue
            }
            let stub = StubTransport([route: .init(status: testCase.status, body: testCase.body.encoded)])
            let wire = try await call(testClient(stub))

            let served = testCase.body.normalized
            #expect(
                wire == (testCase.call == "lookup" ? Self.readingHeldMembers(served) : served),
                "\(label): the answer is not what was served",
            )
            for (name, want) in testCase.expect.present {
                #expect(wire[name] == want.normalized, "\(label): \(name)")
            }
            for name in testCase.expect.objects {
                switch wire[name] {
                case .object?, .array?:
                    continue
                default:
                    Issue.record("\(label): \(name) must be present")
                }
            }
            for name in testCase.expect.empty {
                #expect(wire[name] == .object([:]) || wire[name] == .array([]), "\(label): \(name) must be empty")
            }
            for name in testCase.expect.absent {
                if Self.heldFlags.contains(name) {
                    #expect(
                        wire[name] == .bool(false), "\(label): \(name) is held at Bool, so absent reads false",
                    )
                } else {
                    #expect(wire[name] == nil, "\(label): \(name) must be ABSENT, not false or empty")
                }
            }
            for (object, names) in testCase.expect.absentIn ?? [:] {
                for name in names {
                    if object == "asn", Self.heldInAsn.contains(name) {
                        #expect(
                            wire[object]?[name] == .string(""),
                            "\(label): \(object).\(name) is held at String, so absent reads empty",
                        )
                    } else {
                        #expect(wire[object]?[name] == nil, "\(label): \(object).\(name) must be ABSENT")
                    }
                }
            }
        }
    }

    // Classification is by RANGE, so a 404 or a 422 is a client error and is never
    // retried, and a 429 is a throttle only with `Retry-After`. A lookup refusal's
    // message is its `error` and a database refusal's its `rc`; every case runs
    // against both, as every SDK runs them.
    @Test(
        "a refusal is classified by range and Retry-After, on a lookup and a database call", arguments: Call.allCases,
    )
    func errorsAreClassifiedByRange(_ call: Call) async throws {
        for testCase in corpus.errors {
            let route = StubTransport.Route(
                status: testCase.status, body: testCase.body.encoded, headers: testCase.headers,
            )
            // A non-retryable case is sent with retries ON, so the request count
            // below is what says it was not retried: with retries off one request
            // is guaranteed, and a classifier that retried every failure passed
            // this test unchanged. A retryable case keeps them off so it surfaces
            // here rather than looping; retryableErrorsAreRetried is what asserts
            // that one does retry.
            let stub = StubTransport([call.route: route])
            let client = testClient(stub, retries: testCase.expect.retryable ? 0 : 2)

            let failure = await #expect(throws: InternetDataError.self) {
                try await call.run(client)
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
            await #expect(stub.callCount == 1, "\(testCase.name): a client error must not be retried")
        }
    }

    // A retryable failure is the other half of the same rule: pinning only that
    // nothing is retried would pass on a client that never retries at all.
    @Test("a retryable refusal really is retried", arguments: Call.allCases)
    func retryableErrorsAreRetried(_ call: Call) async throws {
        let retryable = corpus.errors.filter { $0.expect.retryable }
        #expect(retryable.isEmpty == false, "the corpus pins no retryable failure")

        for testCase in retryable {
            let route = StubTransport.Route(
                status: testCase.status, body: testCase.body.encoded, headers: testCase.headers,
            )
            let stub = StubTransport([call.route: route])

            await #expect(throws: InternetDataError.self) {
                try await call.run(testClient(stub, retries: 1))
            }
            await #expect(stub.callCount == 2, "\(testCase.name): one attempt plus one retry")
        }
    }

    @Test("batch dedupes, short-circuits bogons and keys by address")
    func batchDedupesAndKeysByAddress() async throws {
        let testCase = corpus.batchCase("dedup-bogon-and-order-free-keying")
        let stub = StubTransport.answering("1.1.1.1", "8.8.8.8")

        let results = try await testClient(stub).lookupBatch(testCase.input)

        #expect(results.keys == testCase.expect.keys)
        await #expect(stub.callCount == testCase.expect.httpRequests)
        for ip in testCase.expect.bogonKeys ?? [] {
            #expect(try results[ip]?.get().isBogon == true, "\(ip) should be a local answer")
        }
    }

    @Test("one bad address does not lose the rest of the batch")
    func partialFailureDoesNotFailTheBatch() async throws {
        let testCase = corpus.batchCase("partial-failure-does-not-fail-the-batch")
        let client = testClient(StubTransport.answering("1.1.1.1"), retries: 0)

        let results = try await client.lookupBatch(testCase.input)

        #expect(results.keys == testCase.expect.keys)
        for ip in testCase.expect.errorKeys ?? [] {
            guard case .failure(let error) = results[ip] else {
                Issue.record("\(ip) should carry its own error")
                continue
            }
            #expect(error.kind.rawValue == testCase.expect.errorKinds?[ip], "\(ip)")
        }
        #expect(try results["1.1.1.1"]?.get().ip == "1.1.1.1", "the good address still answered")
    }

    @Test("a cache hit issues no second request")
    func cacheHitIssuesNoSecondRequest() async throws {
        let testCase = corpus.batchCase("cache-hit-issues-no-second-request")
        let stub = StubTransport.answering("1.1.1.1")
        let client = testClient(stub)

        for _ in 0..<(testCase.repeat ?? 1) {
            _ = try await client.lookupBatch(testCase.input)
        }
        await #expect(stub.callCount == testCase.expect.httpRequests)
    }

    // A per-entry failure carries no headers, so its 429 can only be a spent
    // allowance, and a 500 is the server's; neither is retried per entry, because
    // retries belong to the call and the call succeeded.
    @Test("an entry error is classified by its status")
    func entryErrorIsClassifiedByItsStatus() async throws {
        let testCase = corpus.batchCase("an-entry-error-is-classified-by-its-status")
        var routes = StubTransport.answers(for: ["1.1.1.1"])
        routes["8.8.8.8"] = .json(
            ["error": "overage cap reached; raise or remove it in Billing"], status: 429,
        )
        routes["9.9.9.9"] = .json(["error": "lookup failed"], status: 500)
        let stub = StubTransport(routes)
        let client = testClient(stub, retries: 3)

        let results = try await client.lookupBatch(testCase.input)

        #expect(results.keys == testCase.expect.keys)
        for (ip, kind) in testCase.expect.errorKinds ?? [:] {
            guard case .failure(let error) = results[ip] else {
                Issue.record("\(ip) should carry its error")
                continue
            }
            #expect(error.kind.rawValue == kind, "\(ip)")
        }
        await #expect(stub.callCount == testCase.expect.httpRequests)
    }

    @Test("two clients never share a cached answer")
    func twoClientsNeverShareACachedAnswer() async throws {
        let stub = StubTransport.answering("1.1.1.1")
        let a = testClient(stub, apiKey: "key-a")
        let b = testClient(stub, apiKey: "key-b")

        _ = try await a.lookup("1.1.1.1")
        _ = try await b.lookup("1.1.1.1")

        // Two keys can be on different plans and so entitled to different
        // fields; a shared cache would serve one of them the other's shape.
        await #expect(stub.callCount == 2)
    }

    @Test("the compiled-in bogon table matches the corpus")
    func bogonTableMatchesTheCorpus() {
        // Both are emitted by the same generator run, so a mismatch means one of
        // the two was regenerated without the other.
        #expect(Bogons.v4 == corpus.bogons.v4)
        #expect(Bogons.v6 == corpus.bogons.v6)
    }

    @Test("every generated bogon range parses")
    func bogonTableParses() {
        for cidr in Bogons.v4 {
            #expect(V4Range(cidr) != nil, "\(cidr) does not parse")
        }
        for cidr in Bogons.v6 {
            #expect(V6Range(cidr) != nil, "\(cidr) does not parse")
        }
        #expect(bogonRangesV4.count == Bogons.v4.count)
        #expect(bogonRangesV6.count == Bogons.v6.count)
    }

    // The tables above read members by their WIRE name; this is what stops a typo
    // in the corpus or in them from quietly satisfying an assertion.
    @Test("every wire name the corpus asserts is a member of the served answer")
    func corpusWireNamesAreRealKeys() {
        var names = Set(
            corpus.bogonResponse.flagsFalse + corpus.bogonResponse.emptyObjects
                + corpus.bogonResponse.emptyLists,
        )
        names.formUnion(corpus.bogonResponse.answer.objectValue.keys)
        for testCase in corpus.lookup {
            let members = testCase.expect.present.keys.map { $0 } + testCase.expect.objects
                + testCase.expect.empty + testCase.expect.absent
            for name in members {
                switch testCase.call {
                case "lookupAsn":
                    #expect(Components.Schemas.AsnLookupResponse.CodingKeys(rawValue: name) != nil, "\(name)")
                case "lookupDomain":
                    #expect(Components.Schemas.DomainLookupResponse.CodingKeys(rawValue: name) != nil, "\(name)")
                default:
                    names.insert(name)
                }
            }
        }
        for name in names {
            #expect(Components.Schemas.LookupResponse.CodingKeys(rawValue: name) != nil, "\(name) is not served")
        }
    }

    @Test("the vocabularies the API answers with are the ones the library exposes")
    func vocabulariesMatchTheCorpus() {
        #expect(Set(Database.Standing.known.map(\.rawValue)) == Set(corpus.standings))
        #expect(
            Set(Database.LicenseType.known.map(\.rawValue)) == Set(corpus.license_type),
        )
        #expect(Set(DatabaseFormat.known.map(\.rawValue)) == Set(corpus.formats))
    }

    static let vocabularyPaths = [
        "myEntitlement": StubTransport.entitlementPath,
        "listDatabases": StubTransport.listPath,
        "listDownloads": StubTransport.downloadsPath,
    ]

    // Each vocabulary case serves a value no published list holds, or the plan's
    // name, and reads it back through the typed result by its wire path. A path
    // the result does not surface reads as absent, so a case the corpus adds stays
    // red until this SDK reads it.
    @Test("every vocabulary case reads as served", arguments: Corpus.shared.vocabulary.cases.map(\.name))
    func vocabularyReadsAsServed(_ name: String) async throws {
        let testCase = corpus.vocabularyCase(name)
        let path = try #require(Self.vocabularyPaths[testCase.call], "\(name): no call \(testCase.call)")
        let stub = StubTransport([path: .init(status: 200, body: testCase.answer.encoded)])
        let read = try await Self.read(testCase.call, testClient(stub, retries: 0))

        #expect(!testCase.expect.isEmpty, "\(name) asserts nothing")
        for (key, want) in testCase.expect {
            #expect(read.at(key) == want, "\(name): \(key)")
        }
    }

    // A wrong type, an empty value or a null where the member is required is
    // still an answer the call cannot read; only a null license type, no license
    // at all, reads.
    @Test(
        "a vocabulary member of the wrong type is refused",
        arguments: [
            ("entitlement-tier-unknown", "plan.tier"),
            ("database-standing-unknown", "databases.0.standing"),
            ("database-license-type-unknown", "databases.0.license_type"),
            ("database-format-unknown", "databases.0.versions.0.formats.0"),
            ("download-outcome-unknown", "downloads.0.outcome"),
        ],
    )
    func vocabularyWrongTypeIsRefused(_ name: String, _ member: String) async throws {
        let testCase = corpus.vocabularyCase(name)
        let path = try #require(Self.vocabularyPaths[testCase.call])
        let nullable = member.hasSuffix("license_type")
        for served: JSONValue in [.int(1), .string(""), .bool(true), .object([:]), .null] {
            let body = testCase.answer.setting(member, to: served).encoded
            let stub = StubTransport([path: .init(status: 200, body: body)])
            do {
                let read = try await Self.read(testCase.call, testClient(stub, retries: 0))
                #expect(served == .null && nullable, "\(name): \(member) as \(served) was read")
                #expect(read.at(member) == .null, "\(name): \(member)")
            } catch let error as InternetDataError {
                #expect(!(served == .null && nullable), "\(name): a null \(member) was refused")
                #expect(error.kind == .serverError, "\(name): \(member) as \(served)")
            }
        }
    }

    @Test("a value outside a list compares by what was served")
    func vocabularyComparesByValue() {
        #expect(Database.Standing(rawValue: "licensed") == .licensed)
        #expect(Database.Standing.licensed.isKnown)
        #expect(!Database.Standing(rawValue: "suspended").isKnown)
        #expect(Database.Standing(rawValue: "suspended") == Database.Standing(rawValue: "suspended"))
        #expect(Database.Standing(rawValue: "suspended") != .licensed)
        #expect(Entitlement.Plan.Tier.known.map(\.rawValue) == ["free", "starter", "scale", "max"])
        #expect("\(Download.Outcome(rawValue: "throttled"))" == "throttled")
    }

    @Test("a format outside the published list is refused before the network")
    func unpublishedFormatIsRefused() async {
        let stub = StubTransport()
        let client = testClient(stub)
        let parquet = DatabaseFormat(rawValue: "parquet")
        let calls: [(String, () async throws -> Void)] = [
            ("checksums", { _ = try await client.database.checksums(id: "bogon_ip_v1", format: parquet) }),
            ("downloadURL", { _ = try await client.database.downloadURL(id: "bogon_ip_v1", format: parquet) }),
            ("downloadBytes", { _ = try await client.database.downloadBytes("bogon_ip_v1", format: parquet) }),
        ]
        for (name, call) in calls {
            do {
                try await call()
                Issue.record("\(name) sent a format no list holds")
            } catch let error as InternetDataError {
                #expect(error.kind == .badRequest, "\(name)")
            } catch {
                Issue.record("\(name): \(error)")
            }
        }
        #expect(await stub.callCount == 0)
    }

    static func read(_ call: String, _ client: InternetDataClient) async throws -> JSONValue {
        switch call {
        case "myEntitlement": tree(try await client.myEntitlement())
        case "listDatabases": tree(try await client.database.list())
        default: tree(try await client.database.downloads())
        }
    }

    // Each typed result as the wire paths the vocabulary cases name.
    static func tree(_ ent: Entitlement) -> JSONValue {
        .object([
            "plan": .object([
                "key": .string(ent.plan.key),
                "name": .string(ent.plan.name),
                "tier": .string(ent.plan.tier.rawValue),
            ]),
        ])
    }

    static func tree(_ databases: [Database]) -> JSONValue {
        .object([
            "databases": .array(databases.map { database in
                .object([
                    "base": .string(database.base),
                    "standing": .string(database.standing.rawValue),
                    "license_type": database.licenseType.map { .string($0.rawValue) } ?? .null,
                    "versions": .array(database.versions.map { version in
                        .object([
                            "id": .string(version.id),
                            "formats": .array(version.formats.map { .string($0.rawValue) }),
                            "sample_formats": version.sampleFormats.map { .array($0.map { .string($0.rawValue) }) }
                                ?? .null,
                        ])
                    }),
                ])
            }),
        ])
    }

    static func tree(_ downloads: [Download]) -> JSONValue {
        .object([
            "downloads": .array(downloads.map { download in
                .object([
                    "dataset_id": .string(download.datasetId),
                    "format": .string(download.format),
                    "outcome": .string(download.outcome.rawValue),
                ])
            }),
        ])
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

        let databases = try await testClient(stub).database.list()

        #expect(databases.map(\.base) == served, "the listing was reordered, padded or dropped")
    }

    /// no-catalog-is-compiled-into-the-client. An organization that licenses
    /// nothing and may see nothing gets an empty list, not a built-in catalog.
    @Test("nothing is synthesized when the server lists nothing")
    func noCatalogIsCompiledIntoTheClient() async throws {
        let stub = StubTransport([StubTransport.listPath: .json(["databases": []])])

        let databases = try await testClient(stub).database.list()

        #expect(databases.isEmpty, "the client invented a catalog the server did not serve")
    }

    /// a-listing-is-never-reused-across-clients. Two keys can hold different
    /// licenses, so a catalog cached against one is not a catalog for another.
    @Test("a listing is never cached, within a client or across two")
    func listingIsNeverReusedAcrossClients() async throws {
        let stub = StubTransport([
            StubTransport.listPath: .json(["databases": [family("bogon_ip", standing: "licensed")]])
        ])

        let first = testClient(stub, apiKey: "key-a")
        _ = try await first.database.list()
        _ = try await first.database.list()
        _ = try await testClient(stub, apiKey: "key-b").database.list()

        await #expect(stub.callCount == 3, "a listing was served from a cache")
        await #expect(stub.authorizations == ["Bearer key-a", "Bearer key-a", "Bearer key-b"])
    }
}

extension ConformanceTests {
    /// The two kinds of call every refusal in the corpus is run against.
    enum Call: String, CaseIterable, Sendable {
        case lookup, database

        var route: String {
            switch self {
            case .lookup: "1.1.1.1"
            case .database: StubTransport.metadataPath
            }
        }

        func run(_ client: InternetDataClient) async throws {
            switch self {
            case .lookup: _ = try await client.lookup("1.1.1.1")
            case .database: _ = try await client.database.metadata(id: "bogon_ip_v1")
            }
        }
    }

    /// A served address answer as this library reads it: a held flag it does not
    /// carry is false, and the AS's type it does not carry is empty.
    static func readingHeldMembers(_ served: JSONValue) -> JSONValue {
        guard case .object(var members) = served else {
            return served
        }
        for name in heldFlags where members[name] == nil {
            members[name] = .bool(false)
        }
        if case .object(var asn)? = members["asn"] {
            for name in heldInAsn where asn[name] == nil {
                asn[name] = .string("")
            }
            members["asn"] = .object(asn)
        }
        return .object(members)
    }

    /// Where a lookup case is served from, and the call that reads it back, or
    /// nil for a call this library does not have.
    static func route(
        _ testCase: Corpus.LookupCase,
    ) -> (String, @Sendable (InternetDataClient) async throws -> JSONValue)? {
        switch (testCase.call, testCase.target) {
        case ("lookup", .string(let ip)):
            return (ip, { try await $0.lookup(ip).wire })
        case ("lookupAsn", .int(let number)):
            guard let asn = UInt32(exactly: number) else {
                return nil
            }
            return ("asn/\(asn)", { try await $0.lookupASN(asn).wire })
        case ("lookupDomain", .string(let domain)):
            return ("domain/\(domain)", { try await $0.lookupDomain(domain).wire })
        default:
            return nil
        }
    }

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
            "open": false,
            "license_type": standing == "licensed" ? "standard" : NSNull(),
            "starts": standing == "licensed" ? "2026-09-04T18:04:26.431Z" : NSNull(),
            "expires": NSNull(),
            "versions": [[
                "id": "\(base)_v1", "version": 1, "summary": "v1", "formats": ["csvgz"],
            ]],
        ]
    }
}
