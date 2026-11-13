import Foundation
import HTTPTypes
import InternetData
import OpenAPIRuntime
import Testing

/// The published package looking addresses, an AS and a domain up without a
/// key, against staging and production alike: Unlimited, the free plan, costs
/// nothing, so both are read on every run.
///
/// Nothing here pins a field COUNT or a value a database can change. What is
/// asserted is the shape: what every plan answers is there, and what only a
/// paid plan answers is absent rather than false or empty.
@Suite("Lookups without a key")
struct KeylessLookupTests {
    static let hosts = [staging, production]

    @Test("a lookup answers Unlimited's members, and leaves every paid one absent", arguments: hosts)
    func aLookupAnswersUnlimited(_ host: URL) async throws {
        let transport = RecordingTransport(key: "")
        let result = try await keyless(host, transport).lookup(probe)

        #expect(result.ip == probe)
        #expect(result.isBogon == false, "a served answer is not a local one")
        assertUnlimited(result, host)
        #expect(await transport.facts.map(\.path) == ["/\(probe)"])
        print("testing against \(host.absoluteString)")
    }

    @Test("myIP answers the calling address in the same shape", arguments: hosts)
    func myIPAnswersTheCallingAddress(_ host: URL) async throws {
        let result = try await keyless(host, RecordingTransport(key: "")).myIP()

        #expect(result.ip.isEmpty == false)
        assertUnlimited(result, host)
    }

    @Test("an AS answers its registration, and leaves the paid members absent", arguments: hosts)
    func anAsAnswersItsRegistration(_ host: URL) async throws {
        let result = try await keyless(host, RecordingTransport(key: "")).lookupASN(9009)

        #expect(result.asn == 9009)
        #expect(result.name.isEmpty == false, "\(host): AS9009 has no name")
        #expect(result.type == nil && result.numIps == nil && result.prefixes == nil, "\(host): a paid member")
        #expect(result.whois == nil && result.trialExpired == nil, "\(host): a paid member")
    }

    @Test("a domain answers whether it is registered, and leaves the paid members absent", arguments: hosts)
    func aDomainAnswersItsRegistration(_ host: URL) async throws {
        let result = try await keyless(host, RecordingTransport(key: "")).lookupDomain("example.com")

        #expect(result.domain == "example.com")
        #expect(result.isRegistered, "\(host): example.com is not registered")
        #expect(result.isDisposable == nil && result.dns == nil, "\(host): a paid member")
        #expect(result.ipRanges == nil && result.disposable == nil, "\(host): a paid member")
    }

    @Test(
        "a batch without a key is refused as unauthorized, once, and its bogon still answered", arguments: hosts,
    )
    func aKeylessBatchIsRefused(_ host: URL) async throws {
        let transport = RecordingTransport(key: "")

        // Two addresses on the wire: a keyless batch of one is answered as its lookup.
        let results = try await keyless(host, transport).lookupBatch([probe, "8.8.8.8", "10.0.0.1"])

        #expect(try results["10.0.0.1"]?.get().isBogon == true)
        guard case .failure(let error) = try #require(results[probe]) else {
            Issue.record("\(host): a batch without a key must fail")
            return
        }
        #expect(error.kind == .unauthorized)
        #expect(error.status == 401)
        #expect(!error.isRetryable)
        #expect(await transport.facts.map(\.path) == ["/batch"], "one request, never retried")
    }

    @Test("myEntitlement without a key is refused as unauthorized", arguments: hosts)
    func aKeylessEntitlementIsRefused(_ host: URL) async throws {
        let failure = await #expect(throws: InternetDataError.self) {
            try await keyless(host, RecordingTransport(key: "")).myEntitlement()
        }
        #expect(try #require(failure).kind == .unauthorized)
    }

    @Test("a bogon is answered without touching the network")
    func aBogonNeverReachesTheNetwork() async throws {
        let refusing = RecordingTransport(key: "", inner: RefusingTransport())

        let result = try await keyless(production, refusing).lookup("10.0.0.1")

        #expect(result.isBogon)
        #expect(result.isVpn == false, "a bogon answers in the widest shape")
        #expect(result.vpn?.isEmpty == true, "a bogon detail is present and empty")
        #expect(isBogon("10.0.0.1"), "the standalone export must agree")
        await #expect(refusing.facts.isEmpty)
    }
}

/// The staging key's lookups. Its organization is on the free plan, so an
/// answer is a paid one for the day's trial and Unlimited's after it, carrying
/// `trialExpired` either way; nothing here depends on which.
@Suite("Lookups with the staging key")
struct KeyedLookupTests {
    @Test("the key reaches the wire, and the answer keeps every member Unlimited answers", Credential.needsKey)
    func aKeyedLookupKeepsUnlimitedsMembers() async throws {
        let transport = RecordingTransport()
        let keyed = try await stagingClient(transport: transport).lookup(probe)
        let unlimited = try await keyless(staging, RecordingTransport(key: "")).lookup(probe)

        // Before anything is compared: an answer to a key that never reached the
        // wire is the keyless one, and containment against it holds vacuously.
        let facts = await transport.facts
        #expect(facts.isEmpty == false, "no request was recorded, so nothing was proved")
        #expect(facts.allSatisfy { $0.carriedKey }, "the staging key never reached the wire")
        #expect(keyed.ip == probe)
        let fields = keyed.servedFields
        for field in unlimited.servedFields {
            #expect(fields.contains(field), "the keyed answer drops \(field), which Unlimited serves")
        }
        if let trialExpired = keyed.trialExpired, trialExpired == false {
            #expect(fields.count > unlimited.servedFields.count, "a trial answer adds nothing to Unlimited's")
        }
    }

    @Test("myEntitlement reads the key's plan and its window", Credential.needsKey)
    func myEntitlementReadsThePlan() async throws {
        let transport = RecordingTransport()
        let entitlement = try await stagingClient(transport: transport).myEntitlement()

        #expect(await transport.facts.allSatisfy { $0.carriedKey }, "the staging key never reached the wire")
        #expect(entitlement.plan.key.isEmpty == false)
        #expect(entitlement.usage.windowEnd > entitlement.usage.windowStart)
    }

    // A free-plan key's batch of two is a 402, and any plan's batch of one is the
    // lookup of that address.
    @Test("a batch of one is answered, and a free plan's batch of two refused once", Credential.needsKey)
    func aKeyedBatchFollowsThePlan() async throws {
        let client = stagingClient(transport: RecordingTransport())
        let tier = try await client.myEntitlement().plan.tier

        let one = try await client.lookupBatch([probe])
        #expect(try one[probe]?.get().ip == probe, "a batch of one failed")

        let transport = RecordingTransport()
        let two = try await stagingClient(transport: transport).lookupBatch(["8.8.8.8", "1.1.1.1"])
        for ip in ["8.8.8.8", "1.1.1.1"] {
            switch (tier, try #require(two[ip])) {
            case (.free, .failure(let error)):
                #expect(error.kind == .badRequest && error.status == 402 && !error.isRetryable, "\(ip)")
            case (.free, .success):
                Issue.record("\(ip): a free plan's batch of two was answered")
            case (_, .success(let result)):
                #expect(result.ip == ip)
            case (_, .failure(let error)):
                Issue.record("\(ip): a paid plan's batch failed: \(error)")
            }
        }
        #expect(await transport.facts.map(\.path) == ["/batch"], "one request, never retried")
    }
}

func keyless(_ host: URL, _ transport: RecordingTransport) -> InternetDataClient {
    InternetDataClient(options: .init(baseURL: host, transport: transport))
}

/// What every plan answers is there, and every member only a paid plan answers
/// is absent: a mapper that filled one in would read as a plan the key is not on.
func assertUnlimited(_ result: LookupResult, _ host: URL) {
    let paid: [String: Bool] = [
        "is_vpn": result.isVpn != nil, "is_hosting": result.isHosting != nil, "is_cdn": result.isCdn != nil,
        "is_resproxy": result.isResproxy != nil, "vpn": result.vpn != nil, "hosting": result.hosting != nil,
        "web": result.web != nil, "whois": result.whois != nil, "hosted_domains": result.hostedDomains != nil,
        "location.city": result.location.city != nil, "asn.rpki_status": result.asn.rpkiStatus != nil,
        "company.type": result.company.type != nil, "abuse.phone": result.abuse.phone != nil,
        "trial_expired": result.trialExpired != nil,
    ]
    for (name, present) in paid {
        #expect(present == false, "\(host): \(name) is answered without a key")
    }
    #expect(result.tor.isEmpty == (result.isTor == false), "\(host): tor disagrees with is_tor")
    #expect(result.relay.isEmpty == (result.isRelay == false), "\(host): relay disagrees with is_relay")
}

extension LookupResult {
    /// The wire members this answer carried, read back off the typed members:
    /// Swift has no `raw`, and an optional member is exactly one the plan
    /// answers, so a `nil` is a member that was not served. `trial_expired` is
    /// left out, since it marks a free plan's answer rather than a field.
    var servedFields: Set<String> {
        var fields: Set<String> = ["ip", "is_bogon", "is_tor", "is_relay", "location", "asn", "company", "abuse"]
        let optional: [String: Bool] = [
            "is_vpn": isVpn != nil, "is_resproxy": isResproxy != nil, "is_dcproxy": isDcproxy != nil,
            "is_mobproxy": isMobproxy != nil, "is_pubproxy": isPubproxy != nil, "is_hosting": isHosting != nil,
            "is_cdn": isCdn != nil, "vpn": vpn != nil, "resproxy": resproxy != nil, "dcproxy": dcproxy != nil,
            "mobproxy": mobproxy != nil, "pubproxy": pubproxy != nil, "hosting": hosting != nil,
            "cdn": cdn != nil,
            "carrier": carrier != nil, "satellite": satellite != nil, "ssh": ssh != nil, "smtp": smtp != nil,
            "web": web != nil, "dns_resolver": dnsResolver != nil, "bittorrent": bittorrent != nil,
            "whois": whois != nil, "rwhois": rwhois != nil, "hosted_domains": hostedDomains != nil,
            "location.city": location.city != nil, "asn.rpki_status": asn.rpkiStatus != nil,
            "company.type": company.type != nil, "abuse.phone": abuse.phone != nil,
        ]
        for (name, present) in optional where present {
            fields.insert(name)
        }
        return fields
    }
}

/// Fails every request, so "this never reached the network" is a refusal rather
/// than an absence nobody checked.
private struct RefusingTransport: ClientTransport {
    struct Reached: Error {}

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        throw Reached()
    }
}
