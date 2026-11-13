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
        /// The plan the organization is on, e.g. `max`.
        public let key: String
        /// The field tier, which decides how much of a lookup answer comes back.
        public let tier: Tier

        /// How much of a lookup answer comes back.
        ///
        /// What each tier includes is documented on the lookup endpoint rather
        /// than repeated here, so there is one place it can be wrong.
        public enum Tier: String, Sendable, Hashable, CaseIterable {
            case free
            case starter
            case scale
            case max
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
    init(_ wire: Components.Schemas.Entitlement) {
        self.orgID = wire.orgId
        self.apikey = Apikey(wire.apikey)
        self.plan = Plan(wire.plan)
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
    init(_ wire: Components.Schemas.EntitlementPlan) {
        self.key = wire.key
        self.tier = Tier(wire.tier)
    }
}

extension Entitlement.Plan.Tier {
    init(_ wire: Components.Schemas.EntitlementPlan.TierPayload) {
        switch wire {
        case .free: self = .free
        case .starter: self = .starter
        case .scale: self = .scale
        case .max: self = .max
        }
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
