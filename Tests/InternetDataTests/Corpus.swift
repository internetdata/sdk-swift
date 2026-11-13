import Foundation
import Testing

@testable import InternetData

/// The shared conformance corpus that every InternetData SDK asserts.
///
/// Generated into `testdata/` and identical across languages, so a behavior that
/// drifts here fails here rather than surfacing as two client libraries quietly
/// disagreeing about the same address or the same refusal.
struct Corpus: Decodable, Sendable {
    let errors: [ErrorCase]
    let standings: [String]
    let license_type: [String]
    let formats: [String]
    let isBogon: [BogonCase]
    let ipv4Mapped: [MappedCase]
    let bogonResponse: BogonResponse
    let lookup: [LookupCase]
    let batch: [BatchCase]
    let bogons: BogonTable
    let visibility: Visibility
    /// Read loosely, because its cases tell `null` apart from absent.
    let oauth: JSONValue

    struct ErrorCase: Decodable, Sendable {
        let name: String
        let status: Int
        let headers: [String: String]
        let body: JSONValue
        let expect: Expect

        struct Expect: Decodable, Sendable {
            let kind: String
            let retryable: Bool
            let message: String?
            let retryAfterSeconds: Int?
        }
    }

    struct BogonCase: Decodable, Sendable {
        let ip: String
        let expect: Bool
        let why: String
    }

    struct MappedCase: Decodable, Sendable {
        let ip: String
        let carries: String
        let expect: Bool
        let why: String
    }

    struct BogonResponse: Decodable, Sendable {
        let flagsFalse: [String]
        let emptyObjects: [String]
        let emptyLists: [String]
        /// The whole local answer, every member but `ip`, which is the address.
        let answer: JSONValue
    }

    /// One served answer and what each member must read as: `present` with its
    /// value, `objects` there, `empty` there and empty, and `absent`, or absent
    /// inside a shared object (`absentIn`), never read as false or zero.
    struct LookupCase: Decodable, Sendable {
        let name: String
        let call: String
        let target: JSONValue
        let status: Int
        let body: JSONValue
        let expect: Expect

        struct Expect: Decodable, Sendable {
            let present: [String: JSONValue]
            let objects: [String]
            let empty: [String]
            let absent: [String]
            let absentIn: [String: [String]]?
        }
    }

    struct BatchCase: Decodable, Sendable {
        let name: String
        let input: [String]
        let `repeat`: Int?
        let expect: Expect

        struct Expect: Decodable, Sendable {
            let keys: [String]?
            let httpRequests: Int?
            let bogonKeys: [String]?
            let errorKeys: [String]?
            let keyCount: Int?
            let errorKinds: [String: String]?
        }
    }

    struct BogonTable: Decodable, Sendable {
        let v4: [String]
        let v6: [String]
    }

    struct Visibility: Decodable, Sendable {
        let why: String
        /// What a client must do about it. Named rather than exemplified: the
        /// private families are deliberately not listed, because this corpus is
        /// committed into twelve PUBLIC repositories.
        let clientRules: [String]
    }
}

extension Corpus {
    // Located from the source file rather than from a bundle: the corpus is
    // regenerated into the repository root, which is outside any
    // target directory and so cannot be declared as a SwiftPM resource.
    static let shared: Corpus = {
        let path = repositoryRoot.appendingPathComponent("testdata/testdata.json")
        guard let data = try? Data(contentsOf: path),
            let corpus = try? JSONDecoder().decode(Corpus.self, from: data)
        else {
            fatalError("could not read the conformance corpus at \(path.path)")
        }
        return corpus
    }()

    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func batchCase(_ name: String) -> BatchCase {
        guard let found = batch.first(where: { $0.name == name }) else {
            fatalError("the corpus has no batch case named \(name)")
        }
        return found
    }
}

extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let members) = self else {
            return nil
        }
        return members[key]
    }

    var arrayValue: [JSONValue] {
        guard case .array(let values) = self else {
            return []
        }
        return values
    }

    var objectValue: [String: JSONValue] {
        guard case .object(let members) = self else {
            return [:]
        }
        return members
    }

    /// The fixture body as the bytes a server would have sent.
    var encoded: Data {
        guard let data = try? JSONEncoder().encode(self) else {
            fatalError("a corpus fixture body could not be re-encoded")
        }
        return data
    }

    /// The same value as it reads back off the wire, so a whole number held as a
    /// `Double` compares equal to the same number in a fixture.
    var normalized: JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: encoded) else {
            fatalError("a value could not be read back")
        }
        return value
    }
}

// Every answer read back into its WIRE names, every member it holds and none it
// does not, so the suite compares what the library hands back with what the API
// served: a member dropped, renamed or coerced on the way shows up as a key
// missing or a value that changed.
extension LookupResult {
    var wire: JSONValue {
        var fields: [String: JSONValue] = [
            "ip": .string(ip), "is_bogon": .bool(isBogon), "is_tor": .bool(isTor),
            "is_relay": .bool(isRelay), "is_anycast": .bool(isAnycast), "is_carrier": .bool(isCarrier),
            "is_satellite": .bool(isSatellite), "is_ssh": .bool(isSsh), "is_smtp": .bool(isSmtp),
            "is_web": .bool(isWeb), "is_dns_resolver": .bool(isDnsResolver),
            "is_bittorrent": .bool(isBittorrent), "tor": tor.wire, "relay": relay.wire,
            "location": location.wire, "asn": asn.wire, "company": company.wire,
            "hostname": .string(hostname), "abuse": abuse.wire,
        ]
        let flags: [String: Bool?] = [
            "is_vpn": isVpn, "is_resproxy": isResproxy, "is_dcproxy": isDcproxy,
            "is_mobproxy": isMobproxy, "is_pubproxy": isPubproxy, "is_hosting": isHosting,
            "is_cdn": isCdn, "trial_expired": trialExpired,
        ]
        for case (let name, let flag?) in flags {
            fields[name] = .bool(flag)
        }
        let objects: [String: JSONValue?] = [
            "vpn": vpn?.wire, "resproxy": resproxy?.wire, "dcproxy": dcproxy?.wire,
            "mobproxy": mobproxy?.wire, "pubproxy": pubproxy?.wire, "hosting": hosting?.wire,
            "cdn": cdn?.wire, "carrier": carrier?.wire, "satellite": satellite?.wire, "ssh": ssh?.wire,
            "smtp": smtp?.wire, "web": web.map { .array($0.map(\.wire)) },
            "dns_resolver": dnsResolver?.wire, "bittorrent": bittorrent?.wire, "whois": whois?.wire,
            "rwhois": rwhois?.wire, "hosted_domains": hostedDomains.map { .object(["total": .int($0.total)]) },
        ]
        for case (let name, let object?) in objects {
            fields[name] = object
        }
        return JSONValue.object(fields).normalized
    }
}

extension AsnLookupResult {
    var wire: JSONValue {
        var fields: [String: JSONValue] = [
            "asn": .int(asn), "name": .string(name), "country": .string(country),
            "registry": .string(registry), "allocated": .string(allocated), "domain": .string(domain),
        ]
        type.map { fields["type"] = .string($0) }
        let counts: [String: Int?] = [
            "num_ips": numIps, "num_prefixes4": numPrefixes4, "num_prefixes6": numPrefixes6,
            "rpki_valid": rpkiValid, "rpki_invalid": rpkiInvalid, "rpki_not_found": rpkiNotFound,
        ]
        for case (let name, let count?) in counts {
            fields[name] = .int(count)
        }
        whois.map { fields["whois"] = .object($0.mapValues { .string($0) }) }
        prefixes.map { fields["prefixes"] = .array($0.map(\.wire)) }
        trialExpired.map { fields["trial_expired"] = .bool($0) }
        return JSONValue.object(fields).normalized
    }
}

extension AsnPrefix {
    var wire: JSONValue {
        .object([
            "prefix": .string(prefix), "peer_count": .int(peerCount), "rpki_status": .string(rpkiStatus),
            "first_seen": .string(firstSeen), "country": .string(country), "size": .int(size),
            "other_origins": .array(otherOrigins.map { .int($0) }),
        ])
    }
}

extension DomainLookupResult {
    var wire: JSONValue {
        var fields: [String: JSONValue] = [
            "domain": .string(domain), "is_registered": .bool(isRegistered), "has_a": .bool(hasA),
            "has_aaaa": .bool(hasAaaa), "has_mx": .bool(hasMx), "has_ns": .bool(hasNs),
            "has_cname": .bool(hasCname),
        ]
        isDisposable.map { fields["is_disposable"] = .bool($0) }
        dns.map { dns in
            let address = { (record: DnsAddressRecord) in
                JSONValue.object(["ip": .string(record.ip), "last_seen": .string(record.lastSeen)])
            }
            fields["dns"] = .object([
                "a": .array(dns.a.map(address)), "aaaa": .array(dns.aaaa.map(address)),
                "mx": .array(dns.mx.map {
                    .object([
                        "priority": .int($0.priority), "host": .string($0.host), "last_seen": .string($0.lastSeen),
                    ])
                }),
                "ns": .array(dns.ns.map {
                    .object(["host": .string($0.host), "last_seen": .string($0.lastSeen)])
                }),
                "cname": .array(dns.cname.map {
                    .object(["target": .string($0.target), "last_seen": .string($0.lastSeen)])
                }),
            ])
        }
        ipRanges.map { ranges in
            fields["ip_ranges"] = .object([
                "domain": .string(ranges.domain), "redirects_to": .string(ranges.redirectsTo),
                "total": .int(ranges.total), "ipv4": .int(ranges.ipv4),
                "ranges": .array(ranges.ranges.map {
                    .object([
                        "range": .string($0.range), "name": .string($0.name), "country": .string($0.country),
                    ])
                }),
            ])
        }
        disposable.map { detail in
            var members: [String: JSONValue] = [:]
            detail.confidence.map { members["confidence"] = .string($0) }
            detail.providers.map { members["providers"] = .array($0.map { .string($0) }) }
            detail.firstSeen.map { members["first_seen"] = .string($0) }
            detail.lastSeen.map { members["last_seen"] = .string($0) }
            fields["disposable"] = .object(members)
        }
        trialExpired.map { fields["trial_expired"] = .bool($0) }
        return JSONValue.object(fields).normalized
    }
}

// The detail objects: a member the object does not carry is left out, so an
// empty one reads back as `{}`.
private func object(_ members: [String: JSONValue?]) -> JSONValue {
    .object(members.compactMapValues { $0 })
}

extension ClassDetail {
    var wire: JSONValue {
        object([
            "provider": provider.map { .string($0) }, "provider_name": providerName.map { .string($0) },
            "confidence": confidence.map { .string($0) }, "last_seen": lastSeen.map { .string($0) },
        ])
    }
}

extension ProxyDetail {
    var wire: JSONValue {
        object([
            "provider": provider.map { .string($0) }, "provider_name": providerName.map { .string($0) },
            "first_seen": firstSeen.map { .string($0) }, "last_seen": lastSeen.map { .string($0) },
            "hits": hits.map { .int($0) }, "hits_days_pct": hitsDaysPct.map { .int($0) },
            "providers_num": providersNum.map { .int($0) },
        ])
    }
}

extension PubproxyDetail {
    var wire: JSONValue {
        object([
            "entry": entry.map { .bool($0) }, "exit": exit.map { .bool($0) },
            "protocols": protocols.map { .array($0.map { .string($0) }) },
            "num_ports": numPorts.map { .int($0) }, "num_proxies": numProxies.map { .int($0) },
            "last_seen": lastSeen.map { .string($0) }, "last_usable": lastUsable.map { .string($0) },
        ])
    }
}

extension CarrierDetail {
    var wire: JSONValue {
        object([
            "name": name.map { .string($0) }, "mcc": mcc.map { .string($0) }, "mnc": mnc.map { .string($0) },
            "country": country.map { .string($0) }, "confidence": confidence.map { .string($0) },
        ])
    }
}

extension SatelliteDetail {
    var wire: JSONValue {
        object([
            "provider": provider.map { .string($0) }, "provider_name": providerName.map { .string($0) },
            "orbit": orbit.map { .string($0) }, "segment": segment.map { .string($0) },
            "country": country.map { .string($0) }, "asn": asn.map { .int($0) },
            "confidence": confidence.map { .string($0) },
        ])
    }
}

extension SshDetail {
    var wire: JSONValue {
        object([
            "port": port.map { .int($0) }, "banner": banner.map { .string($0) },
            "host_key_fp": hostKeyFp.map { .string($0) }, "session_ok": sessionOk.map { .bool($0) },
            "first_seen": firstSeen.map { .string($0) }, "last_seen": lastSeen.map { .string($0) },
        ])
    }
}

extension SmtpDetail {
    var wire: JSONValue {
        object([
            "port": port.map { .int($0) }, "banner": banner.map { .string($0) },
            "session_ok": sessionOk.map { .bool($0) }, "first_seen": firstSeen.map { .string($0) },
            "last_seen": lastSeen.map { .string($0) },
        ])
    }
}

extension WebDetail {
    var wire: JSONValue {
        .object([
            "port": .int(port), "tls_ok": .bool(tlsOk), "session_ok": .bool(sessionOk),
            "status_code": .int(statusCode), "server": .string(server), "location": .string(location),
            "title": .string(title), "cert_subject_cn": .string(certSubjectCn),
            "cert_subject_o": .string(certSubjectO), "cert_issuer_dn": .string(certIssuerDn),
            "cert_browser_trusted": .bool(certBrowserTrusted), "tls_version": .string(tlsVersion),
            "first_seen": .string(firstSeen), "last_seen": .string(lastSeen),
        ])
    }
}

extension DnsResolverDetail {
    var wire: JSONValue {
        object([
            "port": port.map { .int($0) }, "recursion_available": recursionAvailable.map { .bool($0) },
            "rcode": rcode.map { .int($0) }, "answer_correct": answerCorrect.map { .bool($0) },
            "first_seen": firstSeen.map { .string($0) }, "last_seen": lastSeen.map { .string($0) },
        ])
    }
}

extension BitTorrentDetail {
    var wire: JSONValue {
        object([
            "verified": verified.map { .bool($0) }, "id_matches_ip": idMatchesIp.map { .bool($0) },
            "first_seen": firstSeen.map { .string($0) }, "last_seen": lastSeen.map { .string($0) },
            "last_reachable": lastReachable.map { .string($0) }, "days_seen": daysSeen.map { .int($0) },
            "num_ports": numPorts.map { .int($0) }, "peak_num_ports": peakNumPorts.map { .int($0) },
            "indexer": indexer.map { .bool($0) }, "clients": clients.map { .array($0.map { .string($0) }) },
        ])
    }
}

extension Location {
    var wire: JSONValue {
        object([
            "continent": .string(continent), "continent_name": .string(continentName),
            "country": .string(country), "country_name": .string(countryName),
            "timezone": .string(timezone), "currency_code": .string(currencyCode),
            "currency_name": .string(currencyName), "currency_symbol": .string(currencySymbol),
            "flag_emoji": .string(flagEmoji), "flag_unicode": .string(flagUnicode),
            "region": region.map { .string($0) }, "region_code": regionCode.map { .string($0) },
            "city": city.map { .string($0) }, "postal_code": postalCode.map { .string($0) },
            "latitude": latitude.map { .double($0) }, "longitude": longitude.map { .double($0) },
            "accuracy_radius": accuracyRadius.map { .int($0) }, "geoname_id": geonameId.map { .string($0) },
            "dma_code": dmaCode.map { .string($0) }, "last_changed": lastChanged.map { .string($0) },
        ])
    }
}

extension Asn {
    var wire: JSONValue {
        object([
            "asn": .int(asn), "name": .string(name), "domain": .string(domain), "type": .string(type),
            "prefix": .string(prefix), "country": country.map { .string($0) },
            "rpki_status": rpkiStatus.map { .string($0) },
        ])
    }
}

extension Company {
    var wire: JSONValue {
        object([
            "name": .string(name), "domain": .string(domain), "type": type.map { .string($0) },
            "country": country.map { .string($0) },
        ])
    }
}

extension AbuseContact {
    var wire: JSONValue {
        object([
            "email": .string(email), "name": name.map { .string($0) }, "phone": phone.map { .string($0) },
            "address": address.map { .string($0) }, "country": country.map { .string($0) },
            "network": network.map { .string($0) }, "validated": validated.map { .bool($0) },
            "unvalidated_since": unvalidatedSince.map { .string($0) },
        ])
    }
}

extension Whois {
    var wire: JSONValue {
        .object([
            "id": .string(id), "name": .string(name), "org": .string(org), "country": .string(country),
            "status": .string(status), "source": .string(source), "domain": .string(domain),
            "abuse_email": .string(abuseEmail), "asn": .int(asn),
        ])
    }
}

extension Rwhois {
    var wire: JSONValue {
        .object([
            "id": .string(id), "name": .string(name), "country": .string(country), "source": .string(source),
            "domain": .string(domain), "abuse_email": .string(abuseEmail),
        ])
    }
}
