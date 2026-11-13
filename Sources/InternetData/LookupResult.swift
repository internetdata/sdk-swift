/// What a lookup answers: what every InternetData database says about one
/// address, as much of it as your plan shows.
///
/// An **optional** member is one your plan does not include. It never means "we
/// could not check", so `nil` and `false` are genuinely different answers: `nil`
/// is "not in your plan", `false` is "checked, and no". Write `?? false` when
/// you only care whether the address is flagged, and compare against `nil` when
/// the difference matters. The same holds inside a shared object: `location.city`
/// is `nil` on Unlimited, the free plan.
///
/// A detail object that is present but empty means the flag above it is false,
/// and Web IP's list is empty when ``isWeb`` is. A populated one always carries
/// every one of its keys.
public struct LookupResult: Sendable, Hashable {
    /// The address that was looked up, as parsed: `::ffff:a.b.c.d` answers as
    /// `a.b.c.d`.
    public let ip: String
    /// Reserved space, answered from the address alone. A bogon never reaches
    /// the network: the client answers it in the shape the API does.
    public let isBogon: Bool
    /// In VPN IP: a VPN service's server. Paid plans and the trial.
    public let isVpn: Bool?
    /// In Tor IP: a Tor exit.
    public let isTor: Bool
    /// In Relay IP: an anonymizing relay such as iCloud Private Relay.
    public let isRelay: Bool
    /// In Residential Proxy IP's 90-day window. Paid plans and the trial.
    public let isResproxy: Bool?
    /// In Datacenter Proxy IP's 90-day window. Paid plans and the trial.
    public let isDcproxy: Bool?
    /// In Mobile Proxy IP's 90-day window. Paid plans and the trial.
    public let isMobproxy: Bool?
    /// In Public Proxy IP: a public proxy listens here, or its traffic left
    /// from here. Paid plans and the trial.
    public let isPubproxy: Bool?
    /// In Hosting IP: a hosting or cloud network. Paid plans and the trial.
    public let isHosting: Bool?
    /// In CDN IP: a content delivery network. Paid plans and the trial.
    public let isCdn: Bool?
    /// In Anycast IP: announced from many places at once.
    public let isAnycast: Bool
    /// In Carrier IP: a mobile carrier's address space.
    public let isCarrier: Bool
    /// In Satellite IP: a satellite operator's address space.
    public let isSatellite: Bool
    /// In SSH IP: an SSH server answered here.
    public let isSsh: Bool
    /// In SMTP IP: a mail server answered here.
    public let isSmtp: Bool
    /// In Web IP: a web server answered here on port 80 or 443.
    public let isWeb: Bool
    /// In DNS Resolver IP: an open DNS resolver answered here.
    public let isDnsResolver: Bool
    /// In BitTorrent IP: a BitTorrent client was seen here in the last 90 days.
    public let isBittorrent: Bool

    /// VPN IP's row, empty when `isVpn` is false. Paid plans and the trial.
    public let vpn: ClassDetail?
    /// Tor IP's row, empty when `isTor` is false.
    public let tor: ClassDetail
    /// Relay IP's row, empty when `isRelay` is false.
    public let relay: ClassDetail
    public let resproxy: ProxyDetail?
    public let dcproxy: ProxyDetail?
    public let mobproxy: ProxyDetail?
    public let pubproxy: PubproxyDetail?
    public let hosting: ClassDetail?
    public let cdn: ClassDetail?
    public let carrier: CarrierDetail?
    public let satellite: SatelliteDetail?
    public let ssh: SshDetail?
    public let smtp: SmtpDetail?
    /// A row per port that answered, lowest first; empty when `isWeb` is false.
    public let web: [WebDetail]?
    public let dnsResolver: DnsResolverDetail?
    public let bittorrent: BitTorrentDetail?

    /// Where the address is. Every answer carries it.
    public let location: Location
    /// The network announcing the address. Every answer carries it.
    public let asn: Asn
    /// Who uses the address. Every answer carries it.
    public let company: Company
    /// The name the address's reverse DNS record points to, empty when it has none.
    public let hostname: String
    /// Where to report abuse from the address. Every answer carries it.
    public let abuse: AbuseContact
    public let whois: Whois?
    public let rwhois: Rwhois?
    public let hostedDomains: HostedDomains?
    /// On answers to a key on the free plan only: `false` while its organization's
    /// daily trial of every field lasts, `true` once the answer has Unlimited's.
    public let trialExpired: Bool?
}

/// The detail shape of the VPN, Tor, Relay, Hosting and CDN databases.
///
/// Every key is present when the object is populated; the object is empty when
/// its flag is false.
public struct ClassDetail: Sendable, Hashable {
    /// The provider's ID in its catalog; empty for an unattributed range, and on Tor.
    public let provider: String?
    /// The name the catalog gives the provider, empty where it names none.
    public let providerName: String?
    /// `high`, `medium` or `low`: how sure we are the range is what the flag says.
    public let confidence: String?
    /// The last day the range was seen as such.
    public let lastSeen: String?

    public var isEmpty: Bool {
        provider == nil && providerName == nil && confidence == nil && lastSeen == nil
    }
}

/// The detail shape of the residential, datacenter and mobile proxy databases,
/// over a rolling 90 day window.
public struct ProxyDetail: Sendable, Hashable {
    /// The proxy pool's ID in its catalog, empty where unattributed.
    public let provider: String?
    /// The name the catalog gives it.
    public let providerName: String?
    /// The first day of the window the address was seen as an exit.
    public let firstSeen: String?
    /// The last day it was.
    public let lastSeen: String?
    /// How many times it was seen in the window.
    public let hits: Int?
    /// On what share of the window's days, in percent.
    public let hitsDaysPct: Int?
    /// How many pools it was seen in.
    public let providersNum: Int?

    public var isEmpty: Bool {
        provider == nil && providerName == nil && firstSeen == nil && lastSeen == nil
            && hits == nil && hitsDaysPct == nil && providersNum == nil
    }
}

/// The address in Public Proxy IP, both ends of a proxy: the address it listens
/// on and the address its traffic leaves from.
public struct PubproxyDetail: Sendable, Hashable {
    /// A public proxy listens here.
    public let entry: Bool?
    /// Public proxies' traffic leaves from here.
    public let exit: Bool?
    /// The protocols at either end, empty when unknown.
    public let protocols: [String]?
    /// How many ports a proxy listens on here.
    public let numPorts: Int?
    /// How many proxies' traffic left from here.
    public let numProxies: Int?
    /// The last day one was seen.
    public let lastSeen: String?
    /// The last day one answered a request, empty when none did.
    public let lastUsable: String?

    public var isEmpty: Bool {
        entry == nil && exit == nil && protocols == nil && numPorts == nil && numProxies == nil
            && lastSeen == nil && lastUsable == nil
    }
}

/// The mobile carrier whose address space this is, from Carrier IP.
public struct CarrierDetail: Sendable, Hashable {
    public let name: String?
    /// Its mobile country code.
    public let mcc: String?
    /// Its mobile network code.
    public let mnc: String?
    /// ISO 3166 country code.
    public let country: String?
    /// `high`, `medium` or `low`.
    public let confidence: String?

    public var isEmpty: Bool {
        name == nil && mcc == nil && mnc == nil && country == nil && confidence == nil
    }
}

/// The satellite operator whose address space this is, from Satellite IP.
public struct SatelliteDetail: Sendable, Hashable {
    /// The operator's ID in Satellite IP Provider.
    public let provider: String?
    public let providerName: String?
    /// The orbit: `leo`, `meo` or `geo`.
    public let orbit: String?
    /// Who the space serves, such as consumer or maritime.
    public let segment: String?
    /// ISO 3166 country code.
    public let country: String?
    /// The AS the operator announces it from.
    public let asn: Int?
    /// `high`, `medium` or `low`.
    public let confidence: String?

    public var isEmpty: Bool {
        provider == nil && providerName == nil && orbit == nil && segment == nil && country == nil
            && asn == nil && confidence == nil
    }
}

/// The SSH server that answered here, from SSH IP.
public struct SshDetail: Sendable, Hashable {
    public let port: Int?
    public let banner: String?
    /// Its host key's fingerprint.
    public let hostKeyFp: String?
    /// A session was set up.
    public let sessionOk: Bool?
    /// The first day it answered.
    public let firstSeen: String?
    /// The last day it did.
    public let lastSeen: String?

    public var isEmpty: Bool {
        port == nil && banner == nil && hostKeyFp == nil && sessionOk == nil && firstSeen == nil
            && lastSeen == nil
    }
}

/// The mail server that answered here, from SMTP IP.
public struct SmtpDetail: Sendable, Hashable {
    public let port: Int?
    public let banner: String?
    /// A session was set up.
    public let sessionOk: Bool?
    /// The first day it answered.
    public let firstSeen: String?
    /// The last day it did.
    public let lastSeen: String?

    public var isEmpty: Bool {
        port == nil && banner == nil && sessionOk == nil && firstSeen == nil && lastSeen == nil
    }
}

/// One port a web server answered on, from Web IP.
public struct WebDetail: Sendable, Hashable {
    /// 80 or 443.
    public let port: Int
    /// A TLS handshake completed.
    public let tlsOk: Bool
    /// An HTTP response came back.
    public let sessionOk: Bool
    /// Its status, 0 where none came.
    public let statusCode: Int
    /// Its `Server` header.
    public let server: String
    /// Where it redirected.
    public let location: String
    /// The page's title.
    public let title: String
    /// The certificate's subject common name.
    public let certSubjectCn: String
    /// Its subject organization.
    public let certSubjectO: String
    /// Its issuer.
    public let certIssuerDn: String
    /// Browsers trust it.
    public let certBrowserTrusted: Bool
    /// The TLS version negotiated, empty without TLS.
    public let tlsVersion: String
    /// The first day the port was open.
    public let firstSeen: String
    /// The last day it was.
    public let lastSeen: String
}

/// The open DNS resolver that answered here, from DNS Resolver IP.
public struct DnsResolverDetail: Sendable, Hashable {
    public let port: Int?
    /// It offered recursion.
    public let recursionAvailable: Bool?
    /// Its answer's response code.
    public let rcode: Int?
    /// Its answer was right.
    public let answerCorrect: Bool?
    /// The first day it answered.
    public let firstSeen: String?
    /// The last day it did.
    public let lastSeen: String?

    public var isEmpty: Bool {
        port == nil && recursionAvailable == nil && rcode == nil && answerCorrect == nil
            && firstSeen == nil && lastSeen == nil
    }
}

/// The BitTorrent clients seen here, from BitTorrent IP.
public struct BitTorrentDetail: Sendable, Hashable {
    /// A client here answered, or two or more reported it at once.
    public let verified: Bool?
    /// A client here derived its node ID from the address (BEP 42).
    public let idMatchesIp: Bool?
    /// The first day a client was seen here.
    public let firstSeen: String?
    /// The last day.
    public let lastSeen: String?
    /// The last day one answered, empty when none did.
    public let lastReachable: String?
    /// On how many days.
    public let daysSeen: Int?
    /// Distinct ports over the window.
    public let numPorts: Int?
    /// The most on one day.
    public let peakNumPorts: Int?
    /// A DHT indexer rather than people.
    public let indexer: Bool?
    /// The two-letter codes its clients name themselves by.
    public let clients: [String]?

    public var isEmpty: Bool {
        verified == nil && idMatchesIp == nil && firstSeen == nil && lastSeen == nil
            && lastReachable == nil && daysSeen == nil && numPorts == nil && peakNumPorts == nil
            && indexer == nil && clients == nil
    }
}

/// Where the address is. The first ten members are on every plan, an empty
/// string where unknown; the rest are on paid plans and the trial.
public struct Location: Sendable, Hashable {
    /// The continent code, e.g. `EU`.
    public let continent: String
    public let continentName: String
    /// The ISO 3166-1 alpha-2 country code, e.g. `AT`.
    public let country: String
    public let countryName: String
    /// The IANA time zone, e.g. `Europe/Vienna`.
    public let timezone: String
    /// The ISO 4217 code of the country's currency, e.g. `EUR`.
    public let currencyCode: String
    public let currencyName: String
    public let currencySymbol: String
    public let flagEmoji: String
    /// The flag's code points, e.g. `U+1F1E6 U+1F1F9`.
    public let flagUnicode: String
    /// The region, a state or province.
    public let region: String?
    /// The ISO 3166-2 region code.
    public let regionCode: String?
    public let city: String?
    public let postalCode: String?
    /// The latitude of the city.
    public let latitude: Double?
    /// The longitude of the city.
    public let longitude: Double?
    /// The radius in km holding the true location with 67% confidence.
    public let accuracyRadius: Int?
    /// The GeoNames ID of the city.
    public let geonameId: String?
    /// The US TV market (DMA) code.
    public let dmaCode: String?
    /// The day the range's location last changed.
    public let lastChanged: String?
}

/// The network announcing the address, from IP ASN. `asn` is 0 and the rest
/// empty where no announcement covers it.
public struct Asn: Sendable, Hashable {
    /// The AS number, or 0.
    public let asn: Int
    /// The organization that operates the AS.
    public let name: String
    /// The AS operator's own domain.
    public let domain: String
    /// The kind of network it runs.
    public let type: String
    /// The announced prefix covering the address.
    public let prefix: String
    /// The country its registry assigned it to. Paid plans and the trial.
    public let country: String?
    /// The announcement's RPKI status. Paid plans and the trial.
    public let rpkiStatus: String?
}

/// Who uses the address, from IP Company.
public struct Company: Sendable, Hashable {
    public let name: String
    public let domain: String
    /// `hosting`, `isp`, `business`, `education` or `government`. Paid plans and
    /// the trial.
    public let type: String?
    /// ISO 3166 country code. Paid plans and the trial.
    public let country: String?
}

/// Where to report abuse from the address, from IP Abuse Contact. Everything but
/// `email` is on paid plans and the trial.
public struct AbuseContact: Sendable, Hashable {
    public let email: String
    public let name: String?
    public let phone: String?
    public let address: String?
    /// ISO 3166 country code.
    public let country: String?
    /// The registry block it was derived from.
    public let network: String?
    /// ARIN reports the contact answered its yearly validation.
    public let validated: Bool?
    /// Since when it has not.
    public let unvalidatedSince: String?
}

/// IP Whois's most specific record covering the address.
public struct Whois: Sendable, Hashable {
    /// The network name of the record.
    public let id: String
    /// Its holder.
    public let name: String
    /// The registry's handle for the holder.
    public let org: String
    /// ISO 3166 country code.
    public let country: String
    /// The registry's assignment status.
    public let status: String
    /// The registry, or `rwhois`.
    public let source: String
    /// The holder's domain.
    public let domain: String
    /// The record's abuse contact.
    public let abuseEmail: String
    /// The AS announcing the record's start address.
    public let asn: Int
}

/// IP RWHOIS's most specific network covering the address.
public struct Rwhois: Sendable, Hashable {
    /// The network's identifier on the operator's RWHOIS server.
    public let id: String
    /// Its assignee.
    public let name: String
    /// ISO 3166 country code.
    public let country: String
    /// The operator that published it.
    public let source: String
    /// The contact emails' domain.
    public let domain: String
    /// Its abuse contact.
    public let abuseEmail: String
}

/// From IP Hosted Domains: a count, never the list.
public struct HostedDomains: Sendable, Hashable {
    /// How many registered domains resolve to the address.
    public let total: Int
}

// The one place a served answer becomes the public shape. Absent-versus-false
// survives for free: every member the spec does not require is already an
// Optional, so copying it across cannot collapse `false` into "not in your plan".
extension LookupResult {
    init(_ body: Components.Schemas.LookupResponse) {
        self.ip = body.ip
        self.isBogon = body.isBogon
        self.isVpn = body.isVpn
        self.isTor = body.isTor
        self.isRelay = body.isRelay
        self.isResproxy = body.isResproxy
        self.isDcproxy = body.isDcproxy
        self.isMobproxy = body.isMobproxy
        self.isPubproxy = body.isPubproxy
        self.isHosting = body.isHosting
        self.isCdn = body.isCdn
        self.isAnycast = body.isAnycast
        self.isCarrier = body.isCarrier
        self.isSatellite = body.isSatellite
        self.isSsh = body.isSsh
        self.isSmtp = body.isSmtp
        self.isWeb = body.isWeb
        self.isDnsResolver = body.isDnsResolver
        self.isBittorrent = body.isBittorrent
        self.vpn = body.vpn.map { ClassDetail($0.value1) }
        self.tor = ClassDetail(body.tor.value1)
        self.relay = ClassDetail(body.relay.value1)
        self.resproxy = body.resproxy.map { ProxyDetail($0.value1) }
        self.dcproxy = body.dcproxy.map { ProxyDetail($0.value1) }
        self.mobproxy = body.mobproxy.map { ProxyDetail($0.value1) }
        self.pubproxy = body.pubproxy.map { PubproxyDetail($0.value1) }
        self.hosting = body.hosting.map { ClassDetail($0.value1) }
        self.cdn = body.cdn.map { ClassDetail($0.value1) }
        self.carrier = body.carrier.map { CarrierDetail($0.value1) }
        self.satellite = body.satellite.map { SatelliteDetail($0.value1) }
        self.ssh = body.ssh.map { SshDetail($0.value1) }
        self.smtp = body.smtp.map { SmtpDetail($0.value1) }
        self.web = body.web?.map(WebDetail.init)
        self.dnsResolver = body.dnsResolver.map { DnsResolverDetail($0.value1) }
        self.bittorrent = body.bittorrent.map { BitTorrentDetail($0.value1) }
        self.location = Location(body.location)
        self.asn = Asn(body.asn)
        self.company = Company(body.company)
        self.hostname = body.hostname
        self.abuse = AbuseContact(body.abuse)
        self.whois = body.whois.map(Whois.init)
        self.rwhois = body.rwhois.map(Rwhois.init)
        self.hostedDomains = body.hostedDomains.map { HostedDomains(total: $0.total) }
        self.trialExpired = body.trialExpired
    }
}

extension ClassDetail {
    init(_ wire: Components.Schemas.ClassDetail) {
        self.init(
            provider: wire.provider, providerName: wire.providerName, confidence: wire.confidence,
            lastSeen: wire.lastSeen,
        )
    }

    static let empty = ClassDetail(provider: nil, providerName: nil, confidence: nil, lastSeen: nil)
}

extension ProxyDetail {
    init(_ wire: Components.Schemas.ProxyDetail) {
        self.init(
            provider: wire.provider, providerName: wire.providerName, firstSeen: wire.firstSeen,
            lastSeen: wire.lastSeen, hits: wire.hits, hitsDaysPct: wire.hitsDaysPct,
            providersNum: wire.providersNum,
        )
    }

    static let empty = ProxyDetail(
        provider: nil, providerName: nil, firstSeen: nil, lastSeen: nil, hits: nil, hitsDaysPct: nil,
        providersNum: nil,
    )
}

extension PubproxyDetail {
    init(_ wire: Components.Schemas.PubproxyDetail) {
        self.init(
            entry: wire.entry, exit: wire.exit, protocols: wire.protocols, numPorts: wire.numPorts,
            numProxies: wire.numProxies, lastSeen: wire.lastSeen, lastUsable: wire.lastUsable,
        )
    }

    static let empty = PubproxyDetail(
        entry: nil, exit: nil, protocols: nil, numPorts: nil, numProxies: nil, lastSeen: nil,
        lastUsable: nil,
    )
}

extension CarrierDetail {
    init(_ wire: Components.Schemas.CarrierDetail) {
        self.init(
            name: wire.name, mcc: wire.mcc, mnc: wire.mnc, country: wire.country,
            confidence: wire.confidence,
        )
    }

    static let empty = CarrierDetail(name: nil, mcc: nil, mnc: nil, country: nil, confidence: nil)
}

extension SatelliteDetail {
    init(_ wire: Components.Schemas.SatelliteDetail) {
        self.init(
            provider: wire.provider, providerName: wire.providerName, orbit: wire.orbit,
            segment: wire.segment, country: wire.country, asn: wire.asn, confidence: wire.confidence,
        )
    }

    static let empty = SatelliteDetail(
        provider: nil, providerName: nil, orbit: nil, segment: nil, country: nil, asn: nil,
        confidence: nil,
    )
}

extension SshDetail {
    init(_ wire: Components.Schemas.SshDetail) {
        self.init(
            port: wire.port, banner: wire.banner, hostKeyFp: wire.hostKeyFp, sessionOk: wire.sessionOk,
            firstSeen: wire.firstSeen, lastSeen: wire.lastSeen,
        )
    }

    static let empty = SshDetail(
        port: nil, banner: nil, hostKeyFp: nil, sessionOk: nil, firstSeen: nil, lastSeen: nil,
    )
}

extension SmtpDetail {
    init(_ wire: Components.Schemas.SmtpDetail) {
        self.init(
            port: wire.port, banner: wire.banner, sessionOk: wire.sessionOk, firstSeen: wire.firstSeen,
            lastSeen: wire.lastSeen,
        )
    }

    static let empty = SmtpDetail(port: nil, banner: nil, sessionOk: nil, firstSeen: nil, lastSeen: nil)
}

extension WebDetail {
    init(_ wire: Components.Schemas.WebDetail) {
        self.port = wire.port
        self.tlsOk = wire.tlsOk
        self.sessionOk = wire.sessionOk
        self.statusCode = wire.statusCode
        self.server = wire.server
        self.location = wire.location
        self.title = wire.title
        self.certSubjectCn = wire.certSubjectCn
        self.certSubjectO = wire.certSubjectO
        self.certIssuerDn = wire.certIssuerDn
        self.certBrowserTrusted = wire.certBrowserTrusted
        self.tlsVersion = wire.tlsVersion
        self.firstSeen = wire.firstSeen
        self.lastSeen = wire.lastSeen
    }
}

extension DnsResolverDetail {
    init(_ wire: Components.Schemas.DnsResolverDetail) {
        self.init(
            port: wire.port, recursionAvailable: wire.recursionAvailable, rcode: wire.rcode,
            answerCorrect: wire.answerCorrect, firstSeen: wire.firstSeen, lastSeen: wire.lastSeen,
        )
    }

    static let empty = DnsResolverDetail(
        port: nil, recursionAvailable: nil, rcode: nil, answerCorrect: nil, firstSeen: nil, lastSeen: nil,
    )
}

extension BitTorrentDetail {
    init(_ wire: Components.Schemas.BitTorrentDetail) {
        self.init(
            verified: wire.verified, idMatchesIp: wire.idMatchesIp, firstSeen: wire.firstSeen,
            lastSeen: wire.lastSeen, lastReachable: wire.lastReachable, daysSeen: wire.daysSeen,
            numPorts: wire.numPorts, peakNumPorts: wire.peakNumPorts, indexer: wire.indexer,
            clients: wire.clients,
        )
    }

    static let empty = BitTorrentDetail(
        verified: nil, idMatchesIp: nil, firstSeen: nil, lastSeen: nil, lastReachable: nil, daysSeen: nil,
        numPorts: nil, peakNumPorts: nil, indexer: nil, clients: nil,
    )
}

extension Location {
    init(_ wire: Components.Schemas.Location) {
        self.continent = wire.continent
        self.continentName = wire.continentName
        self.country = wire.country
        self.countryName = wire.countryName
        self.timezone = wire.timezone
        self.currencyCode = wire.currencyCode
        self.currencyName = wire.currencyName
        self.currencySymbol = wire.currencySymbol
        self.flagEmoji = wire.flagEmoji
        self.flagUnicode = wire.flagUnicode
        self.region = wire.region
        self.regionCode = wire.regionCode
        self.city = wire.city
        self.postalCode = wire.postalCode
        self.latitude = wire.latitude
        self.longitude = wire.longitude
        self.accuracyRadius = wire.accuracyRadius
        self.geonameId = wire.geonameId
        self.dmaCode = wire.dmaCode
        self.lastChanged = wire.lastChanged
    }

    /// Every member present and empty, as the API answers a bogon.
    static let empty = Location(
        continent: "", continentName: "", country: "", countryName: "", timezone: "",
        currencyCode: "", currencyName: "", currencySymbol: "", flagEmoji: "", flagUnicode: "",
        region: "", regionCode: "", city: "", postalCode: "", latitude: 0, longitude: 0,
        accuracyRadius: 0, geonameId: "", dmaCode: "", lastChanged: "",
    )
}

extension Asn {
    init(_ wire: Components.Schemas.Asn) {
        self.asn = wire.asn
        self.name = wire.name
        self.domain = wire.domain
        self.type = wire._type
        self.prefix = wire.prefix
        self.country = wire.country
        self.rpkiStatus = wire.rpkiStatus
    }

    /// AS 0 and every other member empty, as the API answers a bogon.
    static let empty = Asn(asn: 0, name: "", domain: "", type: "", prefix: "", country: "", rpkiStatus: "")
}

extension Company {
    init(_ wire: Components.Schemas.Company) {
        self.name = wire.name
        self.domain = wire.domain
        self.type = wire._type
        self.country = wire.country
    }

    static let empty = Company(name: "", domain: "", type: "", country: "")
}

extension AbuseContact {
    init(_ wire: Components.Schemas.AbuseContact) {
        self.email = wire.email
        self.name = wire.name
        self.phone = wire.phone
        self.address = wire.address
        self.country = wire.country
        self.network = wire.network
        self.validated = wire.validated
        self.unvalidatedSince = wire.unvalidatedSince
    }

    static let empty = AbuseContact(
        email: "", name: "", phone: "", address: "", country: "", network: "", validated: false,
        unvalidatedSince: "",
    )
}

extension Whois {
    init(_ wire: Components.Schemas.Whois) {
        self.id = wire.id
        self.name = wire.name
        self.org = wire.org
        self.country = wire.country
        self.status = wire.status
        self.source = wire.source
        self.domain = wire.domain
        self.abuseEmail = wire.abuseEmail
        self.asn = wire.asn
    }

    static let empty = Whois(
        id: "", name: "", org: "", country: "", status: "", source: "", domain: "", abuseEmail: "", asn: 0,
    )
}

extension Rwhois {
    init(_ wire: Components.Schemas.Rwhois) {
        self.id = wire.id
        self.name = wire.name
        self.country = wire.country
        self.source = wire.source
        self.domain = wire.domain
        self.abuseEmail = wire.abuseEmail
    }

    static let empty = Rwhois(id: "", name: "", country: "", source: "", domain: "", abuseEmail: "")
}
