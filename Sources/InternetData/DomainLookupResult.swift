/// What a domain lookup answers, from the latest snapshots: on every plan
/// whether it is registered and which DNS record types it has, and on a paid one
/// the records themselves, the network announcing each address, the other
/// domains on its first IPv4 address, its organization's IP ranges, whether it is
/// a disposable email domain, what its home page says and links to, and the
/// domains whose home page redirects or links to it.
///
/// An optional member is one your plan does not include, never "we could not
/// check". An internationalized name is answered under its punycode spelling.
public struct DomainLookupResult: Sendable, Hashable {
    /// The domain, lowercase and in punycode.
    public let domain: String
    /// In Domain List: a registered domain.
    public let isRegistered: Bool
    /// In Disposable Domain. Paid plans and the trial.
    public let isDisposable: Bool?
    public let hasA: Bool
    public let hasAaaa: Bool
    public let hasMx: Bool
    public let hasNs: Bool
    public let hasCname: Bool
    /// Its records in Domain DNS, up to 100 a type. Paid plans and the trial.
    public let dns: DomainDns?
    /// The network announcing each address in `dns.a` and then `dns.aaaa`, from
    /// IP ASN; empty where it resolves to none. Paid plans and the trial.
    public let hosting: [DomainHost]?
    /// The other registered domains on its first IPv4 address, from IP Hosted
    /// Domains. Paid plans and the trial.
    public let cohostedDomains: CohostedDomains?
    /// The organization's IP ranges, from Domain IP Ranges. Paid plans and the
    /// trial.
    public let ipRanges: DomainIpRanges?
    /// Disposable Domain's row, empty when `isDisposable` is false. Paid plans
    /// and the trial.
    public let disposable: DisposableDetail?
    /// What our crawl last read of its own home page. Paid plans and the trial.
    public let web: DomainWeb?
    /// The registered domains whose home page redirects to it. Paid plans and
    /// the trial.
    public let redirects: DomainRedirects?
    /// The registered domains whose home page links to it. Paid plans and the
    /// trial.
    public let backlinks: DomainBacklinks?
    /// On answers to a key on the free plan only: `false` while its organization's
    /// trial of every field lasts, `true` once the answer has Unlimited's.
    public let trialExpired: Bool?
    /// On answers to a key on a paid plan only: `false` while the answer has every
    /// field, `true` once its organization's overage cap is reached and the answer has
    /// Unlimited's. Lookups answered past the cap are not billed.
    public let capReached: Bool?
}

/// A domain's records in Domain DNS, up to 100 a type.
public struct DomainDns: Sendable, Hashable {
    public let a: [DnsAddressRecord]
    public let aaaa: [DnsAddressRecord]
    public let mx: [DnsMxRecord]
    public let ns: [DnsNsRecord]
    public let cname: [DnsCnameRecord]
}

public struct DnsAddressRecord: Sendable, Hashable {
    public let ip: String
    /// The last day the snapshot saw it.
    public let lastSeen: String
}

public struct DnsMxRecord: Sendable, Hashable {
    public let priority: Int
    /// The mail host.
    public let host: String
    public let lastSeen: String
}

public struct DnsNsRecord: Sendable, Hashable {
    /// The name server.
    public let host: String
    public let lastSeen: String
}

public struct DnsCnameRecord: Sendable, Hashable {
    /// Where it points.
    public let target: String
    public let lastSeen: String
}

/// An address the domain resolves to and the network announcing it.
public struct DomainHost: Sendable, Hashable {
    public let ip: String
    /// As an address lookup's `asn`, every member empty where IP ASN holds none.
    public let asn: Asn
}

/// The other registered domains on a domain's first IPv4 address.
public struct CohostedDomains: Sendable, Hashable {
    /// The domain's first IPv4 address, empty where it has none.
    public let ip: String
    /// How many other registered domains resolve to it.
    public let total: Int
    /// Up to 10 of them, the most popular first, the domain itself left out.
    public let domains: [String]
}

/// What our crawl last read of a domain's own home page, every member empty
/// where it holds none.
public struct DomainWeb: Sendable, Hashable {
    /// The URL of the home page read.
    public let url: String
    /// An English page's title.
    public let title: String
    /// An English page's description.
    public let description: String
    /// The day it was last read.
    public let lastSeen: String
    /// The external hosts it links to.
    public let links: DomainWebLinks
}

/// The external hosts a home page links to.
public struct DomainWebLinks: Sendable, Hashable {
    /// How many.
    public let total: Int
    /// Up to 10 of them.
    public let hosts: [String]
}

/// The registered domains whose home page redirects to a domain.
public struct DomainRedirects: Sendable, Hashable {
    /// How many.
    public let total: Int
    /// Up to 10 of them, the most popular first.
    public let domains: [String]
}

/// The registered domains whose home page links to a domain.
public struct DomainBacklinks: Sendable, Hashable {
    /// How many.
    public let total: Int
    /// Up to 10 of them, the most popular first.
    public let domains: [String]
}

/// The IP ranges of the organization behind a domain, from Domain IP Ranges.
public struct DomainIpRanges: Sendable, Hashable {
    /// The organization's domain.
    public let domain: String
    /// Where its home page redirects, when that is how it was reached.
    public let redirectsTo: String
    /// How many ranges it holds.
    public let total: Int
    /// The IPv4 addresses across them.
    public let ipv4: Int
    /// The first 1000, IPv4 before IPv6, the largest first.
    public let ranges: [DomainIpRange]
}

public struct DomainIpRange: Sendable, Hashable {
    public let range: String
    /// Its registry name.
    public let name: String
    /// ISO 3166 country code.
    public let country: String
}

/// Disposable Domain's row. Every key is present when the object is populated;
/// the object is empty when `isDisposable` is false.
public struct DisposableDetail: Sendable, Hashable {
    /// `high`, `medium` or `low`.
    public let confidence: String?
    /// The providers behind it.
    public let providers: [String]?
    /// The first day seen in use.
    public let firstSeen: String?
    /// The last day.
    public let lastSeen: String?

    public var isEmpty: Bool {
        confidence == nil && providers == nil && firstSeen == nil && lastSeen == nil
    }
}

extension DomainLookupResult {
    init(_ body: Components.Schemas.DomainLookupResponse) {
        self.domain = body.domain
        self.isRegistered = body.isRegistered
        self.isDisposable = body.isDisposable
        self.hasA = body.hasA
        self.hasAaaa = body.hasAaaa
        self.hasMx = body.hasMx
        self.hasNs = body.hasNs
        self.hasCname = body.hasCname
        self.dns = body.dns.map(DomainDns.init)
        self.hosting = body.hosting?.map { DomainHost(ip: $0.ip, asn: Asn($0.asn.value1)) }
        self.cohostedDomains = body.cohostedDomains.map {
            CohostedDomains(ip: $0.ip, total: $0.total, domains: $0.domains)
        }
        self.ipRanges = body.ipRanges.map(DomainIpRanges.init)
        self.disposable = body.disposable.map { DisposableDetail($0.value1) }
        self.web = body.web.map {
            DomainWeb(
                url: $0.url, title: $0.title, description: $0.description, lastSeen: $0.lastSeen,
                links: DomainWebLinks(total: $0.links.total, hosts: $0.links.hosts),
            )
        }
        self.redirects = body.redirects.map { DomainRedirects(total: $0.total, domains: $0.domains) }
        self.backlinks = body.backlinks.map { DomainBacklinks(total: $0.total, domains: $0.domains) }
        self.trialExpired = body.trialExpired
        self.capReached = body.capReached
    }
}

extension DomainDns {
    init(_ wire: Components.Schemas.DomainDns) {
        self.a = wire.a.map { DnsAddressRecord(ip: $0.ip, lastSeen: $0.lastSeen) }
        self.aaaa = wire.aaaa.map { DnsAddressRecord(ip: $0.ip, lastSeen: $0.lastSeen) }
        self.mx = wire.mx.map { DnsMxRecord(priority: $0.priority, host: $0.host, lastSeen: $0.lastSeen) }
        self.ns = wire.ns.map { DnsNsRecord(host: $0.host, lastSeen: $0.lastSeen) }
        self.cname = wire.cname.map { DnsCnameRecord(target: $0.target, lastSeen: $0.lastSeen) }
    }
}

extension DomainIpRanges {
    init(_ wire: Components.Schemas.DomainIpRanges) {
        self.domain = wire.domain
        self.redirectsTo = wire.redirectsTo
        self.total = wire.total
        self.ipv4 = wire.ipv4
        self.ranges = wire.ranges.map { DomainIpRange(range: $0.range, name: $0.name, country: $0.country) }
    }
}

extension DisposableDetail {
    init(_ wire: Components.Schemas.DisposableDetail) {
        self.init(
            confidence: wire.confidence, providers: wire.providers, firstSeen: wire.firstSeen,
            lastSeen: wire.lastSeen,
        )
    }
}
