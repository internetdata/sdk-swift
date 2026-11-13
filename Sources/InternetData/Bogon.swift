/// Whether an address is a bogon: private, loopback, link-local, documentation,
/// multicast or otherwise not routable on the public internet, including the
/// IPv6 equivalents and the 6to4 and Teredo ranges that wrap them.
///
/// The API answers these from the address alone, so the client answers them
/// itself and they never cost a request. The same check is available as
/// ``InternetDataClient/isBogon(_:)`` on a client you already hold.
public func isBogon(_ ip: String) -> Bool {
    let ip = unmapped(ip)
    // Routed on the colon rather than by trying both tables: what still has one
    // is IPv6, the IPv4-compatible ::a.b.c.d included, which stays inside ::/96.
    if ip.contains(":") {
        guard let address = V6Address(ip) else {
            return false
        }
        return bogonRangesV6.contains { $0.contains(address) }
    }
    guard let address = v4ToInt(ip) else {
        return false
    }
    return bogonRangesV4.contains { $0.contains(address) }
}

/// The IPv4 address an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`, in any
/// spelling) carries, and any other string as given.
///
/// A server listening on `::` sees every IPv4 visitor in that form, which read
/// whole is inside `::ffff:0:0/96`, so judging it whole would answer every such
/// visitor locally as a bogon. `::a.b.c.d` is IPv4-compatible rather than
/// mapped, and stays IPv6.
func unmapped(_ ip: String) -> String {
    guard ip.contains(":"), let address = V6Address(ip), address.high == 0,
        address.low >> 32 == 0xffff
    else {
        return ip
    }
    let v4 = UInt32(truncatingIfNeeded: address.low)
    return "\(v4 >> 24).\((v4 >> 16) & 0xff).\((v4 >> 8) & 0xff).\(v4 & 0xff)"
}

extension LookupResult {
    /// The answer a bogon gets, in the shape the API answers one on a paid plan:
    /// every flag present and false, every detail object present and empty (Web
    /// IP's list empty), the shared objects with every member empty and AS 0, and
    /// `isBogon` set, as the API sets it.
    ///
    /// This is deliberately the WIDEST shape regardless of your plan, so do not
    /// infer which fields your plan includes from it.
    static func bogon(_ ip: String) -> LookupResult {
        LookupResult(
            ip: ip, isBogon: true, isVpn: false, isTor: false, isRelay: false,
            isResproxy: false, isDcproxy: false, isMobproxy: false, isPubproxy: false,
            isHosting: false, isCdn: false, isAnycast: false, isCarrier: false, isSatellite: false,
            isSsh: false, isSmtp: false, isWeb: false, isDnsResolver: false, isBittorrent: false,
            vpn: .empty, tor: .empty, relay: .empty, resproxy: .empty, dcproxy: .empty, mobproxy: .empty,
            pubproxy: .empty, hosting: .empty, cdn: .empty, carrier: .empty, satellite: .empty, ssh: .empty,
            smtp: .empty, web: [], dnsResolver: .empty, bittorrent: .empty,
            location: .empty, asn: .empty, company: .empty, hostname: "", abuse: .empty,
            whois: .empty, rwhois: .empty, hostedDomains: HostedDomains(total: 0), trialExpired: nil,
        )
    }
}

// A Swift global is initialized on first use behind a `swift_once`, so the table
// costs nothing to a consumer that never looks an address up. A range that does
// not parse can only mean a broken generated table, so it fails loudly rather
// than quietly shrinking the set of addresses answered locally.
let bogonRangesV4: [V4Range] = Bogons.v4.map {
    guard let range = V4Range($0) else {
        preconditionFailure("generated bogon range \($0) does not parse")
    }
    return range
}

let bogonRangesV6: [V6Range] = Bogons.v6.map {
    guard let range = V6Range($0) else {
        preconditionFailure("generated bogon range \($0) does not parse")
    }
    return range
}

struct V4Range {
    let network: UInt32
    let mask: UInt32

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let bits = UInt32(parts[1]), bits <= 32,
            let address = v4ToInt(String(parts[0]))
        else {
            return nil
        }
        self.mask = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        self.network = address & self.mask
    }

    func contains(_ address: UInt32) -> Bool { address & mask == network }
}

struct V6Range {
    let network: V6Address
    let mask: V6Address

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let bits = UInt32(parts[1]), bits <= 128,
            let address = V6Address(String(parts[0]))
        else {
            return nil
        }
        self.mask = V6Address(prefixLength: bits)
        self.network = address.masked(by: self.mask)
    }

    func contains(_ address: V6Address) -> Bool { address.masked(by: mask) == network }
}

// A 128 bit address as two halves. The stdlib's UInt128 would be tidier but it
// only exists from macOS 15 and iOS 18, far above this package's floor.
struct V6Address: Hashable {
    let high: UInt64
    let low: UInt64

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    init(prefixLength bits: UInt32) {
        self.high = bits == 0 ? 0 : ~UInt64(0) << (64 - min(bits, 64))
        self.low = bits <= 64 ? 0 : ~UInt64(0) << (128 - bits)
    }

    func masked(by mask: V6Address) -> V6Address {
        V6Address(high: high & mask.high, low: low & mask.low)
    }
}

/// Whether a string is an IPv4 or an IPv6 address, read as the bogon ranges are.
func isAddress(_ ip: String) -> Bool {
    ip.contains(":") ? V6Address(ip) != nil : v4ToInt(ip) != nil
}

func v4ToInt(_ ip: String) -> UInt32? {
    let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else {
        return nil
    }
    var value: UInt32 = 0
    for part in parts {
        guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
            let byte = UInt32(part), byte <= 255
        else {
            return nil
        }
        value = value << 8 | byte
    }
    return value
}

extension V6Address {
    // Handles the `::` run and a trailing IPv4 literal (::ffff:1.2.3.4), which
    // several of the canonical ranges use.
    init?(_ ip: String) {
        var text = Substring(ip)
        if let lastColon = ip.lastIndex(of: ":"), ip[ip.index(after: lastColon)...].contains(".") {
            guard let embedded = v4ToInt(String(ip[ip.index(after: lastColon)...])) else {
                return nil
            }
            text = ip[...lastColon] + "\(String(embedded >> 16, radix: 16)):"
                + String(embedded & 0xffff, radix: 16)
        }

        let groups: [Substring]
        if let run = text.firstRange(of: "::") {
            // Empty groups are kept, so a second run (1::2::3) or a stray colon
            // (1:::2) fails the group check below rather than being read as one.
            let head = Self.split(text[text.startIndex..<run.lowerBound])
            let tail = Self.split(text[run.upperBound...])
            guard head.count + tail.count <= 8 else {
                return nil
            }
            groups = head + Array(repeating: Substring("0"), count: 8 - head.count - tail.count) + tail
        } else {
            groups = text.split(separator: ":", omittingEmptySubsequences: false)
            guard groups.count == 8 else {
                return nil
            }
        }

        var high: UInt64 = 0
        var low: UInt64 = 0
        for (index, group) in groups.enumerated() {
            guard (1...4).contains(group.count), group.allSatisfy(\.isHexDigit),
                let word = UInt64(group, radix: 16)
            else {
                return nil
            }
            if index < 4 {
                high = high << 16 | word
            } else {
                low = low << 16 | word
            }
        }
        self.init(high: high, low: low)
    }

    private static func split(_ groups: Substring) -> [Substring] {
        groups.isEmpty ? [] : groups.split(separator: ":", omittingEmptySubsequences: false)
    }
}
