import Testing

@testable import InternetData

/// Prefix arithmetic the shared corpus cannot reach.
///
/// The corpus pins addresses that sit comfortably inside or outside a range,
/// so a mask that is a bit too wide or too narrow still answers all of them
/// correctly. These are the pairs either side of a boundary, chosen to exercise
/// prefixes in the high half and one exactly at 64. No prefix in the low half
/// has a public neighbour since `::/3` became a bogon, so none is pinned.
@Suite("Bogon prefixes")
struct BogonTests {
    @Test(
        "an address either side of a v6 prefix boundary",
        arguments: [
            ("3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff", true),  // last address of 3fff::/20
            ("3fff:1000::", false),  // first past 3fff::/20
            ("2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff", true),  // last address of 2001::/23
            ("2001:200::", false),  // first past 2001::/23
            ("2001:0:a9fe::1", true),  // inside the teredo 169.254.0.0/16 wrap, /48
            ("2001:0:a9ff::1", false),  // first past it
            ("2001:0:c058:6302:ffff:ffff:ffff:ffff", true),  // teredo 192.88.99.2/32, a /64
            ("2001:0:c058:6303::", false),  // first past it
            ("::ffff:10.0.0.1", true),  // IPv4-mapped: judged as 10.0.0.1
            ("::ffff:8.8.8.8", false),  // IPv4-mapped: judged as 8.8.8.8
        ],
    )
    func v6PrefixBoundaries(ip: String, expected: Bool) {
        #expect(isBogon(ip) == expected)
    }

    @Test("a malformed address is not a bogon rather than a crash")
    func malformedAddressesAreRejected() {
        for ip in [
            "", "notanip", "1.2.3", "1.2.3.4.5", "256.0.0.1", "1.2.3.-1", "::gggg", "1::2::3",
            "1:::2", ":1::2", "1::2:",
        ] {
            #expect(isBogon(ip) == false, "\(ip)")
        }
    }
}
