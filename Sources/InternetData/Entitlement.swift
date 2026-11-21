import Foundation

/// What an API key is entitled to, and what it has spent.
///
/// Everything here describes the key that asked: there is no way to enquire
/// about another organization, because the credential IS the question.
public struct Entitlement: Sendable, Hashable {
    /// The organization the key belongs to.
    public let orgID: String
    public let apikey: Apikey
    public let plan: Plan
    public let usage: Usage

    /// The credential itself.
    ///
    /// The key is never echoed back - only its ID, which is what the console
    /// shows and what you can act on.
    public struct Apikey: Sendable, Hashable {
        public let id: String
        /// `nil` for a key with no end date, which is the normal case.
        public let expires: Date?
        /// The source addresses this key may be used from. EMPTY means
        /// unrestricted, never "deny all".
        public let allowedCIDRs: [String]
    }

    /// The plan behind the key, and the field tier it buys.
    public struct Plan: Sendable, Hashable {
        /// The plan the organization is on, as an identifier that is never
        /// renamed or reused: `free` for the free plan, or a paid plan's key.
        /// Compare against it, and show ``name``.
        public let key: String
        /// The plan's name as the site and console show it: `Unlimited` for the
        /// free plan. Show this rather than a name built from ``key``.
        public let name: String
        /// The field tier, which decides how much of a lookup answer comes back.
        public let tier: Tier

        /// How much of a lookup answer comes back.
        ///
        /// What each tier includes is documented on the lookup endpoint rather
        /// than repeated here, so there is one place it can be wrong. A tier
        /// this release was not built with reads as served.
        public struct Tier: Vocabulary {
            public let rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            public static let free = Tier(rawValue: "free")
            public static let starter = Tier(rawValue: "starter")
            public static let scale = Tier(rawValue: "scale")
            public static let max = Tier(rawValue: "max")

            public static let known: [Tier] = [.free, .starter, .scale, .max]
        }
    }

    /// Consumption against the plan's allowance, in the current window.
    public struct Usage: Sendable, Hashable {
        /// Requests counted in the current window. The same number a lookup is
        /// gated on, and it can lag by a few seconds.
        public let requests: Int64
        /// What the plan includes. Zero on a plan that includes none.
        public let quota: Int64
        /// Where we stop serving. `nil` means NEVER, which is the normal state
        /// of an uncapped paid plan and is not the same as zero. Above the
        /// quota and below this, requests are served and billed as overage.
        public let hardLimit: Int64?
        /// When the current allowance period began.
        public let windowStart: Date
        /// When the allowance next resets.
        public let windowEnd: Date
    }
}

extension Entitlement {
    init(_ wire: Components.Schemas.Entitlement) throws {
        self.orgID = wire.orgId
        self.apikey = Apikey(wire.apikey)
        self.plan = try Plan(wire.plan)
        self.usage = Usage(wire.usage)
    }
}

extension Entitlement.Apikey {
    init(_ wire: Components.Schemas.EntitlementApikey) {
        self.id = wire.id
        self.expires = wire.expires
        self.allowedCIDRs = wire.allowedCidrs
    }
}

extension Entitlement.Plan {
    init(_ wire: WireEntitlementPlan) throws {
        self.key = wire.key
        self.name = wire.name
        self.tier = try vocabulary(wire.tier, "tier")
    }
}

extension Entitlement.Usage {
    init(_ wire: Components.Schemas.EntitlementUsage) {
        self.requests = wire.requests
        self.quota = wire.quota
        self.hardLimit = wire.hardLimit
        self.windowStart = wire.windowStart
        self.windowEnd = wire.windowEnd
    }
}

/// `EntitlementPlan` as decoded, in place of the generated type
/// (`typeOverrides` in the generator config): the generated one reads `tier` as
/// an enum, which refuses a tier the API added since.
struct WireEntitlementPlan: Codable, Hashable, Sendable {
    var key: String
    var name: String
    var tier: String
}
