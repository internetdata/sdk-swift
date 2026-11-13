/// What a domain lookup answers, from the latest snapshots: on every plan
/// whether it is registered and which DNS record types it has, and on a paid one
/// the records themselves, its organization's IP ranges and whether it is a
/// disposable email domain.
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
    /// The organization's IP ranges, from Domain IP Ranges. Paid plans and the
    /// trial.
    public let ipRanges: DomainIpRanges?
    /// Disposable Domain's row, empty when `isDisposable` is false. Paid plans
    /// and the trial.
    public let disposable: DisposableDetail?
    /// On answers to a key on the free plan only: `false` while its organization's
    /// daily trial of every field lasts, `true` once the answer has Unlimited's.
    public let trialExpired: Bool?
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
        self.ipRanges = body.ipRanges.map(DomainIpRanges.init)
        self.disposable = body.disposable.map { DisposableDetail($0.value1) }
        self.trialExpired = body.trialExpired
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
