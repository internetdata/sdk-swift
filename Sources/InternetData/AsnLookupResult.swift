/// What an AS lookup answers: its registration on every plan, and on a paid one
/// its ASN Whois record, every prefix it announces in global BGP, its rank and
/// neighbors from ASN Extended, and the domains it hosts.
///
/// An optional member is one your plan does not include, never "we could not
/// check". An AS no database knows answers its number with empty values.
public struct AsnLookupResult: Sendable, Hashable {
    /// The AS number.
    public let asn: Int
    /// Its operator.
    public let name: String
    /// The country its registry assigned it to.
    public let country: String
    /// The registry that allocated it.
    public let registry: String
    /// When it was allocated.
    public let allocated: String
    /// Its operator's domain.
    public let domain: String
    /// The kind of network it runs. Paid plans and the trial.
    public let type: String?
    /// The IPv4 addresses it announces. Paid plans and the trial.
    public let numIps: Int?
    /// The IPv4 prefixes it announces. Paid plans and the trial.
    public let numPrefixes4: Int?
    /// The IPv6 prefixes it announces. Paid plans and the trial.
    public let numPrefixes6: Int?
    /// Its announcements RPKI calls valid. Paid plans and the trial.
    public let rpkiValid: Int?
    /// Its announcements RPKI calls invalid. Paid plans and the trial.
    public let rpkiInvalid: Int?
    /// Its announcements with no RPKI record. Paid plans and the trial.
    public let rpkiNotFound: Int?
    /// Its ASN Whois record, every column, empty where the registry states
    /// nothing. Paid plans and the trial.
    public let whois: [String: String]?
    /// What it announces, IPv4 then IPv6, up to 20000 a family. Paid plans and
    /// the trial.
    public let prefixes: [AsnPrefix]?
    /// Its rank in ASN Extended by customer cone, 1 the largest; 0 for an AS
    /// seen in no AS path. Paid plans and the trial.
    public let rank: Int?
    /// Whether it is one of the transit-free networks at the top of the
    /// hierarchy. Paid plans and the trial.
    public let tier1: Bool?
    /// How many AS numbers it gets transit from. Paid plans and the trial.
    public let numUpstreams: Int?
    /// Those AS numbers, ascending, up to 20000. Paid plans and the trial.
    public let upstreams: [Int]?
    /// How many AS numbers it exchanges its own and its customers' routes with.
    /// Paid plans and the trial.
    public let numPeers: Int?
    /// Those AS numbers, ascending, up to 20000. Paid plans and the trial.
    public let peers: [Int]?
    /// How many AS numbers it provides transit to. Paid plans and the trial.
    public let numDownstreams: Int?
    /// Those AS numbers, ascending, up to 20000. Paid plans and the trial.
    public let downstreams: [Int]?
    /// How many registered domains it hosts, and the 10 most popular. Paid plans
    /// and the trial.
    public let hostedDomains: AsnHostedDomains?
    /// On answers to a key on the free plan only: `false` while its organization's
    /// daily trial of every field lasts, `true` once the answer has Unlimited's.
    public let trialExpired: Bool?
    /// On answers to a key on a paid plan only: `false` while the answer has every
    /// field, `true` once its organization's overage cap is reached and the answer has
    /// Unlimited's. Lookups answered past the cap are not billed.
    public let capReached: Bool?
}

/// From ASN Hosted Domains: how many registered domains the AS hosts, and the 10 most popular.
public struct AsnHostedDomains: Sendable, Hashable {
    /// How many registered domains resolve to an address the AS announces.
    public let total: Int
    /// Up to 10 of them, the most popular first; empty when none does.
    public let domains: [String]?
}

/// One prefix an AS announces.
public struct AsnPrefix: Sendable, Hashable {
    /// The announced prefix.
    public let prefix: String
    /// How many peers saw it.
    public let peerCount: Int
    /// Its RPKI status.
    public let rpkiStatus: String
    /// The first day BGP Route saw it.
    public let firstSeen: String
    /// Where its first address is.
    public let country: String
    /// The IPv4 addresses it covers; 0 for IPv6.
    public let size: Int
    /// Every other AS announcing it.
    public let otherOrigins: [Int]
}

extension AsnLookupResult {
    init(_ wire: Components.Schemas.AsnLookupResponse) {
        self.asn = wire.asn
        self.name = wire.name
        self.country = wire.country
        self.registry = wire.registry
        self.allocated = wire.allocated
        self.domain = wire.domain
        self.type = wire._type
        self.numIps = wire.numIps
        self.numPrefixes4 = wire.numPrefixes4
        self.numPrefixes6 = wire.numPrefixes6
        self.rpkiValid = wire.rpkiValid
        self.rpkiInvalid = wire.rpkiInvalid
        self.rpkiNotFound = wire.rpkiNotFound
        self.whois = wire.whois?.additionalProperties
        self.prefixes = wire.prefixes?.map(AsnPrefix.init)
        self.rank = wire.rank
        self.tier1 = wire.tier1
        self.numUpstreams = wire.numUpstreams
        self.upstreams = wire.upstreams
        self.numPeers = wire.numPeers
        self.peers = wire.peers
        self.numDownstreams = wire.numDownstreams
        self.downstreams = wire.downstreams
        self.hostedDomains = wire.hostedDomains.map { AsnHostedDomains(total: $0.total, domains: $0.domains) }
        self.trialExpired = wire.trialExpired
        self.capReached = wire.capReached
    }
}

extension AsnPrefix {
    init(_ wire: Components.Schemas.AsnPrefix) {
        self.prefix = wire.prefix
        self.peerCount = wire.peerCount
        self.rpkiStatus = wire.rpkiStatus
        self.firstSeen = wire.firstSeen
        self.country = wire.country
        self.size = wire.size
        self.otherOrigins = wire.otherOrigins
    }
}
