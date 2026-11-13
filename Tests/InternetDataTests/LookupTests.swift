import Foundation
import HTTPTypes
import NIOHTTP1
import OpenAPIRuntime
import Testing

@testable import InternetData

/// The lookup surface: the batch, the cache, the per-call options, the self
/// endpoints and the AS and domain lookups, as distinct from the shared corpus.
@Suite("Lookup")
struct LookupTests {
    // A group primed with no children waits for none, forever.
    @Test("a per-call concurrency below 1 is refused before any request", arguments: [0, -1])
    func concurrencyBelowOneIsRefused(_ concurrency: Int) async throws {
        let stub = StubTransport.answering("9.9.9.9")
        let client = client(stub)

        let failure = await #expect(throws: InternetDataError.self) {
            try await client.lookupBatch(["9.9.9.9"], options: .init(concurrency: concurrency))
        }

        #expect(try #require(failure).kind == .badRequest)
        await #expect(stub.callCount == 0)
    }

    @Test("retries are configurable per call")
    func retriesAreConfigurablePerCall() async throws {
        let stub = StubTransport([
            "9.9.9.9": .json(["error": "lookup failed"], status: 500),
        ])
        let client = client(stub, cache: nil, retries: 0)

        await #expect(throws: InternetDataError.self) {
            try await client.lookup("9.9.9.9", retries: 2)
        }
        // One initial attempt plus two retries, rather than the client's zero.
        await #expect(stub.callCount == 3)
    }

    @Test("a spent quota is never retried")
    func spentQuotaIsNeverRetried() async throws {
        let stub = StubTransport([
            "9.9.9.9": .json(["error": "overage cap reached; raise or remove it in Billing"], status: 429),
        ])
        let client = client(stub, cache: nil, retries: 5)

        let failure = await #expect(throws: InternetDataError.self) {
            try await client.lookup("9.9.9.9")
        }
        #expect(try #require(failure).kind == .quotaExceeded)
        await #expect(stub.callCount == 1)
    }

    @Test("a rate limit is retried after the server-supplied wait")
    func rateLimitWaitsForRetryAfter() async throws {
        var route = StubTransport.Route.json(["error": "per-minute limit exceeded"], status: 429)
        route.headers = ["Retry-After": "1"]
        let stub = StubTransport(["9.9.9.9": route])
        let client = client(stub, cache: nil, retries: 1)

        let started = ContinuousClock.now
        await #expect(throws: InternetDataError.self) {
            try await client.lookup("9.9.9.9")
        }
        await #expect(stub.callCount == 2)
        // The header, not the backoff schedule, decides the wait.
        #expect(ContinuousClock.now - started >= .seconds(1))
    }

    @Test("cancelling a lookup propagates rather than becoming a network failure")
    func cancellingALookupPropagates() async throws {
        let stub = StubTransport(StubTransport.answers(for: ["9.9.9.1"]), delay: .seconds(5))
        // Retries OFF on purpose: with them on the backoff sleep is itself
        // cancelled and the error escapes that way, so only a zero-retry client
        // reaches the code that decides what a cancellation looks like.
        let client = client(stub, cache: nil, retries: 0)

        let call = Task { try await client.lookup("9.9.9.1") }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
    }

    @Test("isBogon is on the client and agrees with the standalone function")
    func isBogonIsOnTheClientAndAgrees() {
        let client = client(StubTransport())
        for testCase in Corpus.shared.isBogon {
            #expect(client.isBogon(testCase.ip) == testCase.expect, "\(testCase.ip)")
            #expect(client.isBogon(testCase.ip) == InternetData.isBogon(testCase.ip))
        }
    }

    // The lookups the generated client cannot read go through the same middlewares
    // by a path of their own, so the key is asserted on each of them.
    @Test("the api key is presented on every lookup, and no key means no header")
    func apiKeyIsPresentedOnEveryLookup() async throws {
        for (apiKey, header) in [("sk-test", "Bearer sk-test"), (nil, nil)] as [(String?, String?)] {
            let stub = StubTransport([
                "1.1.1.1": .json(StubTransport.answer(for: "1.1.1.1")),
                "myip": .json(StubTransport.answer(for: "8.8.8.8")),
                "asn/9009": .json(Self.asnAnswer),
                "domain/example.com": .json(Self.domainAnswer),
                "8.8.4.4": .json(StubTransport.answer(for: "8.8.4.4")),
                "9.9.9.9": .json(StubTransport.answer(for: "9.9.9.9")),
            ])
            let client = client(stub, apiKey: apiKey)

            _ = try await client.lookup("1.1.1.1")
            _ = try await client.myIP()
            _ = try await client.lookupASN(9009)
            _ = try await client.lookupDomain("example.com")
            _ = try await client.lookupBatch(["8.8.4.4", "9.9.9.9"])

            let sent = await stub.authorizations
            #expect(sent == Array(repeating: header, count: 5), "apiKey \(String(describing: apiKey))")
        }
    }

    @Test("a key holding a control character is refused on a lookup before anything is sent")
    func controlCharacterKeyIsRefusedOnALookup() async throws {
        let stub = StubTransport.answering("1.1.1.1")
        let failure = await #expect(throws: InternetDataError.self) {
            try await client(stub, apiKey: "sk\u{01}test", cache: nil).lookup("1.1.1.1")
        }
        #expect(try #require(failure).kind == .badRequest)
        await #expect(stub.callCount == 0)
    }

    // A proxy's page, a cut-off or empty body, or an answer without the member
    // it requires is the server's fault, on the generated path and this client's
    // own alike.
    @Test("a 2xx a lookup cannot read is a retried server error carrying its status")
    func unreadableAnswerIsRetriedServerError() async throws {
        let calls: [(String, String, @Sendable (InternetDataClient) async throws -> Void)] = [
            ("1.1.1.1", "{\"ip\":", { _ = try await $0.lookup("1.1.1.1") }),
            ("myip", "{\"ip\":", { _ = try await $0.myIP() }),
            ("asn/9009", "{\"asn\":", { _ = try await $0.lookupASN(9009) }),
            ("domain/example.com", "{\"domain\":", { _ = try await $0.lookupDomain("example.com") }),
            (StubTransport.entitlementPath, "{\"org_id\":", { _ = try await $0.myEntitlement() }),
        ]
        for (route, cutOff, call) in calls {
            for body in ["<html>gateway</html>", cutOff, "", "null", "[]", "{}"] {
                let stub = StubTransport([route: .init(body: Data(body.utf8))])
                let failure = await #expect(throws: InternetDataError.self) {
                    try await call(client(stub, cache: nil, retries: 2))
                }
                #expect(try #require(failure).kind == .serverError, "\(route) \(body.debugDescription)")
                #expect(try #require(failure).status == 200, "\(route) \(body.debugDescription)")
                await #expect(stub.callCount == 3, "\(route) \(body.debugDescription)")
            }
        }
    }

    // A detail object requires no member: `{}` under a false flag is present and
    // empty. What the spec does not allow anywhere else is still no answer.
    @Test("a detail object of {} is present and empty, and a value the spec forbids is a retried server error")
    func aDetailObjectOfNothingIsPresentAndEmpty() async throws {
        var empty = StubTransport.answer(for: "1.1.1.1")
        empty["vpn"] = [String: Any]()
        empty["is_vpn"] = false
        empty["web"] = [Any]()
        let stub = StubTransport(["1.1.1.1": .json(empty)])
        let result = try await client(stub).lookup("1.1.1.1")
        #expect(result.vpn?.isEmpty == true, "{} is present and empty")
        #expect(result.web == [], "[] is present and empty")
        #expect(result.tor.isEmpty && result.relay.isEmpty)

        var nullTor = StubTransport.answer(for: "1.1.1.1")
        nullTor["tor"] = NSNull()
        var webOfNull = StubTransport.answer(for: "1.1.1.1")
        webOfNull["web"] = [NSNull()]
        var detailOfList = StubTransport.answer(for: "1.1.1.1")
        detailOfList["ssh"] = [Any]()
        var hitsString = StubTransport.answer(for: "1.1.1.1")
        hitsString["dcproxy"] = ["hits": "3"]
        var latitudeString = StubTransport.answer(for: "1.1.1.1")
        var location = latitudeString["location"] as? [String: Any] ?? [:]
        location["latitude"] = "48.2"
        latitudeString["location"] = location
        let unreadable: [(String, [String: Any])] = [
            ("tor of null", nullTor), ("web of [null]", webOfNull), ("ssh of []", detailOfList),
            ("dcproxy.hits of \"3\"", hitsString), ("location.latitude of \"48.2\"", latitudeString),
        ]
        for (name, body) in unreadable {
            let stub = StubTransport(["1.1.1.1": .json(body)])
            let failure = await #expect(throws: InternetDataError.self) {
                try await client(stub, retries: 1).lookup("1.1.1.1")
            }
            #expect(try #require(failure).kind == .serverError, "\(name)")
            #expect(try #require(failure).status == 200, "\(name)")
            await #expect(stub.callCount == 2, "\(name)")
        }
    }

    // The corpus answers leave most detail objects empty, so every one is served
    // populated here, each member a value of its own, and read back whole: a member
    // mapped to its neighbor's field reads back as the neighbor's value.
    @Test("every member of a whole answer reads back as served")
    func everyMemberOfAWholeAnswerReadsBack() async throws {
        func row(_ n: Int) -> [String: Any] {
            ["provider": "p\(n)", "provider_name": "P\(n)", "confidence": "c\(n)", "last_seen": "2026-01-\(n)"]
        }
        func proxy(_ n: Int) -> [String: Any] {
            [
                "provider": "p\(n)", "provider_name": "P\(n)", "first_seen": "2025-01-\(n)",
                "last_seen": "2026-01-\(n)",
                "hits": n, "hits_days_pct": n + 1, "providers_num": n + 2,
            ]
        }
        var body = StubTransport.answer(for: "1.1.1.1")
        for flag in ["is_vpn", "is_resproxy", "is_dcproxy", "is_mobproxy", "is_pubproxy", "is_hosting", "is_cdn"] {
            body[flag] = true
        }
        body["vpn"] = row(10)
        body["tor"] = row(11)
        body["relay"] = row(12)
        body["hosting"] = row(13)
        body["cdn"] = row(14)
        body["resproxy"] = proxy(15)
        body["dcproxy"] = proxy(16)
        body["mobproxy"] = proxy(17)
        body["pubproxy"] = [
            "entry": true, "exit": false, "protocols": ["http", "socks5"], "num_ports": 3, "num_proxies": 4,
            "last_seen": "2026-02-01", "last_usable": "2026-02-02",
        ]
        body["carrier"] = ["name": "n", "mcc": "232", "mnc": "01", "country": "AT", "confidence": "high"]
        body["satellite"] = [
            "provider": "s", "provider_name": "S", "orbit": "leo", "segment": "consumer", "country": "US",
            "asn": 14593,
            "confidence": "medium",
        ]
        body["ssh"] = [
            "port": 22, "banner": "b", "host_key_fp": "f", "session_ok": true, "first_seen": "2025-03-01",
            "last_seen": "2026-03-01",
        ]
        body["smtp"] = [
            "port": 25, "banner": "m", "session_ok": false, "first_seen": "2025-04-01", "last_seen": "2026-04-01",
        ]
        body["dns_resolver"] = [
            "port": 53, "recursion_available": true, "rcode": 5, "answer_correct": false, "first_seen": "2025-05-01",
            "last_seen": "2026-05-01",
        ]
        body["bittorrent"] = [
            "verified": true, "id_matches_ip": false, "first_seen": "2025-06-01", "last_seen": "2026-06-01",
            "last_reachable": "2026-06-02", "days_seen": 7, "num_ports": 8, "peak_num_ports": 9, "indexer": false,
            "clients": ["UT", "qB"],
        ]
        body["whois"] = [
            "id": "i", "name": "n", "org": "o", "country": "c", "status": "s", "source": "r", "domain": "d",
            "abuse_email": "a", "asn": 1,
        ]
        body["rwhois"] = [
            "id": "i2", "name": "n2", "country": "c2", "source": "r2", "domain": "d2", "abuse_email": "a2",
        ]
        body["hosted_domains"] = ["total": 42]
        let stub = StubTransport(["1.1.1.1": .json(body)])

        let result = try await client(stub).lookup("1.1.1.1")

        let served = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: body))
        #expect(result.wire == served.normalized)
    }

    // The API answers an AS or a domain at the lookup's own path, in a shape the
    // call cannot read, so `lookup` refuses what is no address before sending it.
    // A batch's addresses are refused by the API entry by entry instead.
    @Test("lookup refuses what is no address before sending, naming the calls that take one")
    func aStringThatIsNoAddressIsRefused() async throws {
        let stub = StubTransport.answering("1.1.1.1")
        let client = client(stub, retries: 2)

        for target in ["example.com", "AS15169", "15169", "notanip", "", "1.2.3", "::gggg", " 1.1.1.1"] {
            let failure = await #expect(throws: InternetDataError.self, "\(target.debugDescription)") {
                try await client.lookup(target)
            }
            let error = try #require(failure)
            #expect(error.kind == .badRequest, "\(target.debugDescription)")
            #expect(error.message.contains("lookupASN") && error.message.contains("lookupDomain"), "\(error.message)")
        }
        await #expect(stub.callCount == 0, "a string that is no address reached the network")
        let failure = await #expect(throws: InternetDataError.self) { try await client.lookup("example.com") }
        #expect(
            failure?.message
                == "'example.com' is not an IP address: look up an AS with lookupASN, and a domain with lookupDomain",
        )
        #expect(failure?.isRetryable == false)

        let results = try await client.lookupBatch(["example.com", "1.1.1.1"])
        await #expect(stub.batchIps == ["example.com", "1.1.1.1"], "a batch sends what it is given")
        guard case .failure(let error) = results["example.com"] else {
            Issue.record("the API's refusal of a batch entry was lost")
            return
        }
        #expect(error.kind == .badRequest)
    }

    // A lookup refusal carries `error` and a database refusal `rc`; an empty one
    // says nothing.
    @Test("an empty message in the envelope gives way to the other member, then the status")
    func emptyEnvelopeMessageGivesWay() async throws {
        let cases: [([String: Any], String)] = [
            (["error": "invalid API key", "rc": "UNAUTHORIZED"], "invalid API key"),
            (["error": "", "rc": "QUOTA_EXCEEDED"], "QUOTA_EXCEEDED"),
            (["rc": ""], "request failed with status 403"),
            (["error": ""], "request failed with status 403"),
        ]
        for (envelope, message) in cases {
            let stub = StubTransport(["9.9.9.9": .json(envelope, status: 403)])
            let failure = await #expect(throws: InternetDataError.self) {
                try await client(stub).lookup("9.9.9.9")
            }
            #expect(try #require(failure).message == message, "\(envelope)")
        }
    }

    @Test("caching can be turned off")
    func cachingCanBeTurnedOff() async throws {
        let stub = StubTransport.answering("1.1.1.1")
        let client = client(stub, cache: nil)

        for _ in 0..<2 {
            _ = try await client.lookup("1.1.1.1")
        }
        await #expect(stub.callCount == 2)
    }

    @Test("a cached answer lapses when its ttl does")
    func cacheEntriesExpire() async throws {
        let stub = StubTransport.answering("1.1.1.1")
        let client = client(stub, cache: CacheOptions(maxEntries: 10, ttl: .milliseconds(50)))

        _ = try await client.lookup("1.1.1.1")
        try await Task.sleep(for: .milliseconds(120))
        _ = try await client.lookup("1.1.1.1")

        await #expect(stub.callCount == 2)
    }

    @Test("the cache evicts the least recently used entry")
    func cacheEvictsLeastRecentlyUsed() async throws {
        let addresses = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
        let stub = StubTransport(StubTransport.answers(for: addresses))
        let client = client(stub, cache: CacheOptions(maxEntries: 2, ttl: .seconds(60)))

        _ = try await client.lookup("1.1.1.1")
        _ = try await client.lookup("8.8.8.8")
        _ = try await client.lookup("1.1.1.1")
        _ = try await client.lookup("9.9.9.9")
        // 8.8.8.8 is the oldest touch, so it is the one that went.
        _ = try await client.lookup("1.1.1.1")
        _ = try await client.lookup("8.8.8.8")

        await #expect(stub.callCount == 4)
    }

    // Swift has `??`, so the absent-versus-false distinction needs no helper
    // reader the way Go and Java do. This pins the ergonomics the README teaches.
    @Test("an absent flag coalesces to false without losing the distinction")
    func absentFlagCoalescesWithNilCheck() async throws {
        let stub = StubTransport(["1.1.1.1": .json(StubTransport.answer(for: "1.1.1.1"))])
        let free = try await client(stub).lookup("1.1.1.1")

        #expect(free.isHosting == nil, "an answer without is_hosting leaves it nil")
        #expect((free.isHosting ?? false) == false)
        #expect(free.location.city == nil, "a paid member inside a shared object is nil too")

        var paid = StubTransport.answer(for: "8.8.4.4")
        paid["is_hosting"] = false
        let served = StubTransport(["8.8.4.4": .json(paid)])
        let max = try await client(served).lookup("8.8.4.4")
        #expect(max.isHosting == false, "a served false is not the same as absent")
        #expect(max.isHosting != nil)
    }

    // The path is what the generated client would have rendered: every byte but
    // the unreserved characters escaped, so an IPv6 address's colons and a
    // domain's slash cannot change the route.
    @Test("each lookup goes to its path, escaped as the generated client escapes one")
    func eachLookupGoesToItsPath() async throws {
        let stub = StubTransport()
        let client = client(stub, cache: nil, retries: 0)

        _ = try? await client.lookup("2606:4700:4700::1111")
        _ = try? await client.lookupASN(4_294_967_295)
        _ = try? await client.lookupDomain("bücher.de")
        _ = try? await client.lookupDomain("a/b?c")
        _ = try? await client.myIP()

        await #expect(
            stub.targets == [
                "/2606%3A4700%3A4700%3A%3A1111", "/asn/4294967295", "/domain/b%C3%BCcher.de", "/domain/a%2Fb%3Fc",
                "/myip",
            ],
        )
    }

    // Neither is keyed by address, and neither is worth a batch of its own: each
    // call is served.
    @Test("an AS and a domain are looked up every time, never cached")
    func asAndDomainAreNeverCached() async throws {
        let stub = StubTransport([
            "asn/9009": .json(Self.asnAnswer), "domain/example.com": .json(Self.domainAnswer),
        ])
        let client = client(stub)

        let first = try await client.lookupASN(9009)
        _ = try await client.lookupASN(9009)
        let domain = try await client.lookupDomain("example.com")
        _ = try await client.lookupDomain("example.com")

        #expect(first.asn == 9009 && first.registry == "ripe" && first.type == nil)
        #expect(domain.isRegistered && domain.isDisposable == nil && domain.dns == nil)
        await #expect(stub.callCount == 4)
    }

    // A batch asks about addresses alone; the API's `asns` and `domains` stay
    // unwrapped.
    @Test("a batch body carries the addresses and nothing else")
    func aBatchBodyCarriesAddressesAlone() async throws {
        let stub = StubTransport.answering("9.9.9.9", "8.8.8.8")
        let client = client(stub, cache: nil)

        _ = try await client.lookupBatch(["9.9.9.9", "8.8.8.8"])

        await #expect(stub.batchMembers == [["ips"]])
        await #expect(stub.batchIps == ["9.9.9.9", "8.8.8.8"])
    }

    // The spec gives each lookup path a `servers` entry of its own, production's,
    // and a client honoring it would send every lookup there whatever base URL it
    // was built with. Each one is served here by a local origin instead.
    @Test("every lookup goes to the client's base URL", .timeLimit(.minutes(1)))
    func everyLookupGoesToTheBaseURL() async throws {
        let lookup = Self.json(StubTransport.answer(for: "146.70.116.130"))
        let batch = Self.json([
            "results": [
                "8.8.8.8": StubTransport.answer(for: "8.8.8.8"), "9.9.9.9": StubTransport.answer(for: "9.9.9.9"),
            ],
            "errors": [String: Any](),
        ])
        let answers: [String: TestOrigin.Answer] = [
            "/146.70.116.130": .json(lookup), "/myip": .json(lookup), "/asn/9009": .json(Self.json(Self.asnAnswer)),
            "/domain/example.com": .json(Self.json(Self.domainAnswer)), "/batch": .json(batch),
            StubTransport.entitlementPath: .json(Self.json(Self.entitlementBody)),
        ]
        let origin = try await TestOrigin.start { answers[$0] ?? .init(status: .notFound) }
        defer { Task { try? await origin.stop() } }
        let client = InternetDataClient(
            options: .init(baseURL: URL(string: "http://127.0.0.1:\(origin.port)")!, cache: nil, retries: 0),
        )

        #expect(try await client.lookup("146.70.116.130").ip == "146.70.116.130")
        #expect(try await client.myIP().ip == "146.70.116.130")
        #expect(try await client.lookupASN(9009).asn == 9009)
        #expect(try await client.lookupDomain("example.com").domain == "example.com")
        #expect(try await client.lookupBatch(["8.8.8.8", "9.9.9.9"])["9.9.9.9"]?.get().ip == "9.9.9.9")
        #expect(try await client.myEntitlement().plan.tier == .max)
        #expect(
            origin.receivedPaths == [
                "/146.70.116.130", "/myip", "/asn/9009", "/domain/example.com", "/batch",
                StubTransport.entitlementPath,
            ],
        )
    }

    @Test("the default base is the API host, and every setting has its default")
    func optionsAreDefaulted() {
        #expect(InternetDataClient.defaultBaseURL.absoluteString == "https://api.internetdata.io")
        #expect(InternetDataClient.Options().baseURL == InternetDataClient.defaultBaseURL)
        #expect(InternetDataClient.Options().concurrency == 8)
        #expect(InternetDataClient.Options().retries == 2)
        #expect(InternetDataClient.Options().timeout == .seconds(30))
        #expect(InternetDataClient.Options().cache?.maxEntries == 10_000)
        #expect(InternetDataClient.Options().cache?.ttl == .seconds(3600))
    }

    // A reference names every parameter, so the initializer from before the cache
    // and the concurrency arrived still has to exist to be named, and take theirs.
    @Test("the earlier options initializer is still there, and takes the new defaults")
    func theEarlierOptionsInitializerRemains() {
        let earlier: (String?, URL, Int, Duration, (any ClientTransport)?) -> InternetDataClient.Options =
            InternetDataClient.Options.init(apiKey:baseURL:retries:timeout:transport:)
        let options = earlier("k", InternetDataClient.defaultBaseURL, 3, .seconds(5), nil)

        #expect(options.retries == 3 && options.timeout == .seconds(5))
        #expect(options.concurrency == 8 && options.cache == CacheOptions())
    }

    @Test("myIP looks up the calling address")
    func myIPLooksUpTheCallingAddress() async throws {
        let stub = StubTransport(["myip": .json(StubTransport.answer(for: "45.83.91.1"))])
        let client = client(stub)

        let result = try await client.myIP()

        #expect(result.ip == "45.83.91.1")
        #expect(result.isBogon == false)
    }

    // The cache is keyed by address, and which address this is IS the question:
    // a machine that moves between networks would otherwise be told where it
    // used to be.
    @Test("myIP is not cached")
    func myIPIsNotCached() async throws {
        let stub = StubTransport(["myip": .json(StubTransport.answer(for: "45.83.91.1"))])
        let client = client(stub)

        _ = try await client.myIP()
        _ = try await client.myIP()

        await #expect(stub.callCount == 2)
    }

    @Test("myEntitlement reports the plan and the usage")
    func myEntitlementReportsThePlanAndTheUsage() async throws {
        let stub = StubTransport([StubTransport.entitlementPath: .json(Self.entitlementBody)])
        let client = client(stub)

        let ent = try await client.myEntitlement()

        #expect(ent.plan.key == "max")
        #expect(ent.plan.tier == .max)
        #expect(ent.usage.requests == 580)
        #expect(ent.usage.quota == 5_000_000)
        // nil means NEVER stop, which is not the same as a limit of zero.
        #expect(ent.usage.hardLimit == nil)
        #expect(ent.apikey.allowedCIDRs.isEmpty)
        #expect(ent.apikey.expires == nil)
    }

    // The whole point is what has been spent.
    @Test("myEntitlement is not cached")
    func myEntitlementIsNotCached() async throws {
        let stub = StubTransport([StubTransport.entitlementPath: .json(Self.entitlementBody)])
        let client = client(stub)

        _ = try await client.myEntitlement()
        _ = try await client.myEntitlement()

        await #expect(stub.callCount == 2)
    }

    // Unlike a lookup there is no useful unauthenticated answer.
    @Test("myEntitlement surfaces an unauthorized key")
    func myEntitlementSurfacesAnUnauthorizedKey() async throws {
        let stub = StubTransport(
            [StubTransport.entitlementPath: .json(["error": "an API key is required"], status: 401)],
        )
        let failure = await #expect(throws: InternetDataError.self) {
            _ = try await client(stub, retries: 0).myEntitlement()
        }
        #expect(try #require(failure).kind == .unauthorized)
        #expect(try #require(failure).message == "an API key is required")
    }
}

extension LookupTests {
    func client(
        _ transport: some ClientTransport,
        apiKey: String? = nil,
        cache: CacheOptions? = CacheOptions(),
        concurrency: Int = 8,
        retries: Int = 2,
    ) -> InternetDataClient {
        InternetDataClient(
            options: .init(
                apiKey: apiKey, cache: cache, concurrency: concurrency,
                retries: retries, transport: transport,
            ),
        )
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    nonisolated(unsafe) static let asnAnswer: [String: Any] = [
        "asn": 9009, "name": "M247 Europe SRL", "country": "RO", "registry": "ripe",
        "allocated": "2005-06-06", "domain": "m247global.com",
    ]

    nonisolated(unsafe) static let domainAnswer: [String: Any] = [
        "domain": "example.com", "is_registered": true, "has_a": true, "has_aaaa": true, "has_mx": true,
        "has_ns": true, "has_cname": false,
    ]

    nonisolated(unsafe) static let entitlementBody: [String: Any] = [
        "org_id": "85bb51e4-2eb6-4a31-8e4d-02ba8b98fe61",
        "apikey": [
            "id": "0ab424cc-7619-4dad-b027-afacdc2cedb0",
            "expires": NSNull(),
            "allowed_cidrs": [String](),
        ],
        "plan": ["key": "max", "tier": "max"],
        "usage": [
            "requests": 580,
            "quota": 5_000_000,
            "hard_limit": NSNull(),
            "window_start": "2026-09-04T07:00:00Z",
            "window_end": "2026-10-04T07:00:00Z",
        ],
    ]
}

/// The batches of thousands, one at a time. Each chunk's answer is read in one
/// stretch on a thread of the concurrency runtime, and run side by side they held
/// every thread a small CI runner has, so the timing tests' deadlines fired late.
/// The tests that count requests are served refusals, which cost next to nothing
/// to read, and the two that read thousands of answers send one chunk at a time.
@Suite("Bulk batch", .serialized)
struct BulkBatchTests {
    // Enough addresses for seven chunks of the batch endpoint's 1000, so a
    // concurrency bound has something to bound: one request per chunk, and only
    // the chunks overlap.
    static let manyAddresses = (0..<6001).map { "9.\(1 + $0 / 65536).\($0 / 256 % 256).\($0 % 256)" }

    // Peak in-flight is the only measurement that tells a real limit from an
    // option that was accepted and ignored.
    @Test("a per-call concurrency is honored, measured at the transport")
    func perCallConcurrencyIsHonored() async throws {
        let stub = StubTransport(
            StubTransport.refusals(for: Self.manyAddresses), delay: .milliseconds(20),
        )
        let client = client(stub, cache: nil)

        _ = try await client.lookupBatch(Self.manyAddresses, options: .init(concurrency: 3))

        await #expect(stub.callCount == 7, "one request per chunk of 1000")
        await #expect(stub.peakInFlight <= 3)
        await #expect(stub.peakInFlight > 1, "requests never overlapped")
    }

    @Test("a per-call concurrency overrides the client default")
    func perCallConcurrencyOverridesTheClientDefault() async throws {
        let stub = StubTransport(
            StubTransport.refusals(for: Self.manyAddresses), delay: .milliseconds(20),
        )
        let client = client(stub, cache: nil, concurrency: 2)

        _ = try await client.lookupBatch(Self.manyAddresses, options: .init(concurrency: 6))

        await #expect(stub.peakInFlight > 2, "the override was ignored")
        await #expect(stub.peakInFlight <= 6)
    }

    @Test("without an override the client concurrency still applies")
    func clientConcurrencyAppliesWithoutAnOverride() async throws {
        let stub = StubTransport(
            StubTransport.refusals(for: Self.manyAddresses), delay: .milliseconds(20),
        )
        let client = client(stub, cache: nil, concurrency: 2)

        _ = try await client.lookupBatch(Self.manyAddresses)

        await #expect(stub.peakInFlight <= 2)
    }

    // No cap on what one call accepts: chunking to the endpoint's 1000 is the
    // library's job, so 2,500 addresses is three requests rather than an error.
    @Test("a batch is never capped, and goes out as one POST per chunk of 1000")
    func aBatchIsNeverCapped() async throws {
        let addresses = (0..<2500).map { "9.9.\($0 / 256).\($0 % 256)" }
        let stub = StubTransport(StubTransport.answers(for: addresses))
        let client = client(stub, cache: nil)

        let results = try await client.lookupBatch(addresses, options: .init(concurrency: 1))

        // The stub answers a batch only as a POST, so an answered address is one
        // that went out that way.
        await #expect(stub.calls == ["batch", "batch", "batch"])
        #expect(results.keys == addresses)
        for ip in addresses {
            guard case .success(let result) = results[ip] else {
                Issue.record("\(ip) was not answered")
                continue
            }
            #expect(result.ip == ip)
        }
    }

    @Test("cancelling a batch propagates rather than becoming per-address failures")
    func cancellingABatchPropagates() async throws {
        let stub = StubTransport(
            StubTransport.answers(for: Self.manyAddresses), delay: .seconds(5),
        )
        let client = client(stub, cache: nil, retries: 0)

        let batch = Task { try await client.lookupBatch(Self.manyAddresses) }
        try await Task.sleep(for: .milliseconds(100))
        batch.cancel()

        // A map of network errors would otherwise look like a completed batch.
        await #expect(throws: CancellationError.self) { try await batch.value }
    }

    // The corpus's two, which in the conformance suite would decode thousands of
    // whole answers beside the timing tests. The second pins that no cap refuses
    // a batch past the endpoint's thousand.
    @Test(
        "a large batch is sent in chunks of a thousand",
        arguments: ["chunks-of-one-thousand", "uncapped-input-is-chunked"],
    )
    func largeBatchIsSentInChunksOfAThousand(_ name: String) async throws {
        let testCase = Corpus.shared.batchCase(name)
        let stub = StubTransport(StubTransport.answers(for: testCase.input))
        let client = InternetDataClient(options: .init(cache: nil, transport: stub))

        let results = try await client.lookupBatch(testCase.input, options: .init(concurrency: 1))

        #expect(results.count == testCase.expect.keyCount)
        await #expect(stub.callCount == testCase.expect.httpRequests)
        for ip in testCase.input {
            #expect(try results[ip]?.get().ip == ip, "\(ip) should be answered for itself")
        }
    }

    func client(
        _ transport: some ClientTransport, cache: CacheOptions? = CacheOptions(), concurrency: Int = 8,
        retries: Int = 2,
    ) -> InternetDataClient {
        InternetDataClient(
            options: .init(cache: cache, concurrency: concurrency, retries: retries, transport: transport),
        )
    }
}

/// The client's timeout and the per-call one on the lookups, each bounding a
/// whole ATTEMPT, against a real socket that took the request.
@Suite("Lookup timeout")
struct LookupTimeoutTests {
    static let perCall: Duration = .milliseconds(250)
    /// Timer slack, so a deadline that fired a hair early is not read as none.
    static let atLeast: Duration = .milliseconds(200)

    enum Call: String, CaseIterable, Sendable {
        case lookup, myIP, myEntitlement, batch, lookupASN, lookupDomain
    }

    // The client keeps its 30 second default, so a failure inside a few seconds is
    // the per-call value firing, and on a body that stalled after its head.
    @Test(
        "a per-call timeout fires as a retryable network error", .timeLimit(.minutes(1)), arguments: Call.allCases,
    )
    func perCallTimeoutFires(_ call: Call) async throws {
        let origin = try await TestOrigin.start { _ in .stalledJSON }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin)

        let started = ContinuousClock.now
        let failure = try await Self.failure(of: call, on: client)
        let elapsed = ContinuousClock.now - started

        #expect(failure.kind == .network)
        #expect(failure.isRetryable)
        #expect(failure.message.hasPrefix("the request timed out"), "\(failure.message)")
        #expect(elapsed >= Self.atLeast, "failed after \(elapsed), before the deadline could fire")
        #expect(elapsed < .seconds(5))
        #expect(origin.receivedPaths.count == 1)
    }

    // No single read waits more than 2 ms, so only a bound on the whole attempt
    // can end this before the answer completes, past a second.
    @Test("a trickled lookup is bounded as a whole, not per read", .timeLimit(.minutes(1)))
    func aTrickledLookupIsBoundedAsAWhole() async throws {
        let origin = try await TestOrigin.start { _ in .trickledLookup }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin, timeout: .milliseconds(300))

        let started = ContinuousClock.now
        let failure = await #expect(throws: InternetDataError.self) {
            try await client.lookup("9.9.9.9")
        }
        let elapsed = ContinuousClock.now - started

        #expect(try #require(failure).kind == .network)
        #expect(elapsed >= Self.atLeast, "failed after \(elapsed), before the deadline could fire")
        #expect(elapsed < .milliseconds(900), "failed after \(elapsed), not at the client's timeout")
    }

    // A per-call value written into the client would pass the first call and fail
    // the second.
    @Test(
        "a per-call timeout lengthens the client's, and leaves it for the next call", .timeLimit(.minutes(1)),
    )
    func aPerCallTimeoutLengthensTheClients() async throws {
        let origin = try await TestOrigin.start { _ in .trickledLookup }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin, timeout: .milliseconds(300))

        let result = try await client.lookup("9.9.9.9", timeout: .seconds(10))
        let failure = await #expect(throws: InternetDataError.self) {
            try await client.myIP()
        }

        #expect(result.ip == "9.9.9.9")
        #expect(try #require(failure).kind == .network)
    }

    // A bogon and a cached answer need no request, so a bound checked only in
    // withDeadline would let either answer it.
    @Test(
        "a lookup refuses an impossible timeout before a bogon or a cached answer",
        arguments: ["10.0.0.1", "9.9.9.9"],
    )
    func aLookupRefusesBeforeAnswering(_ ip: String) async throws {
        let stub = StubTransport.answering("9.9.9.9")
        let client = InternetDataClient(options: .init(apiKey: "key", retries: 0, transport: stub))
        _ = try await client.lookup("9.9.9.9")

        for timeout in [Duration.zero, .seconds(-1), .seconds(Int64.max), maxTimeout + .seconds(1)] {
            let failure = await #expect(throws: InternetDataError.self) {
                try await client.lookup(ip, timeout: timeout)
            }
            #expect(try #require(failure).kind == .badRequest, "\(timeout)")
        }
        #expect(await stub.callCount == 1)
    }

    // A check written into one method is a check the others do not get, and they
    // reach withDeadline by separate paths.
    @Test("every lookup refuses an impossible timeout", arguments: Call.allCases)
    func everyCallRefusesAnImpossibleTimeout(_ call: Call) async throws {
        let stub = StubTransport()
        let client = InternetDataClient(options: .init(cache: nil, retries: 0, transport: stub))

        let failure = try await Self.failure(of: call, on: client, timeout: .zero)

        #expect(failure.kind == .badRequest)
        #expect(await stub.callCount == 0)
    }

    static func client(_ origin: TestOrigin, timeout: Duration = .seconds(30)) -> InternetDataClient {
        InternetDataClient(
            options: .init(
                baseURL: URL(string: "http://127.0.0.1:\(origin.port)")!, cache: nil, retries: 0,
                timeout: timeout,
            ),
        )
    }

    static func failure(
        of call: Call, on client: InternetDataClient, timeout: Duration = perCall,
    ) async throws -> InternetDataError {
        let caught: InternetDataError?
        switch call {
        case .lookup:
            caught = await #expect(throws: InternetDataError.self) {
                try await client.lookup("9.9.9.9", timeout: timeout)
            }
        case .myIP:
            caught = await #expect(throws: InternetDataError.self) {
                try await client.myIP(timeout: timeout)
            }
        case .myEntitlement:
            caught = await #expect(throws: InternetDataError.self) {
                try await client.myEntitlement(timeout: timeout)
            }
        case .lookupASN:
            caught = await #expect(throws: InternetDataError.self) {
                try await client.lookupASN(9009, timeout: timeout)
            }
        case .lookupDomain:
            caught = await #expect(throws: InternetDataError.self) {
                try await client.lookupDomain("example.com", timeout: timeout)
            }
        case .batch:
            do {
                let results = try await client.lookupBatch(["9.9.9.9"], options: .init(timeout: timeout))
                guard case .failure(let error) = results["9.9.9.9"] else {
                    Issue.record("a chunk that timed out must carry the failure")
                    caught = nil
                    break
                }
                caught = error
            } catch let error as InternetDataError {
                caught = error
            }
        }
        return try #require(caught)
    }
}
