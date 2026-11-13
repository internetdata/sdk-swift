/// What an AS lookup answers: its registration on every plan, and on a paid one
/// its ASN Whois record and every prefix it announces in global BGP.
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
    /// On answers to a key on the free plan only: `false` while its organization's
    /// daily trial of every field lasts, `true` once the answer has Unlimited's.
    public let trialExpired: Bool?
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
        self.trialExpired = wire.trialExpired
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
