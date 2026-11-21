/// A value from a list the API may add to: a plan's tier, a database's standing
/// or license type, a file format, a download's outcome.
///
/// Each is a struct rather than an enum, because an enum cannot hold a value it
/// was not built with: an answer carrying a value the API added since this
/// release reads as itself, with ``isKnown`` false, instead of failing the call.
/// Compare with `==` against the static constants. A `switch` needs a `default:`.
public protocol Vocabulary: RawRepresentable, Hashable, Sendable, CustomStringConvertible
where RawValue == String {
    /// A value as the API spells it, one this release was built with or not.
    init(rawValue: String)

    /// Every value this release was built with, in the spec's order.
    static var known: [Self] { get }
}

extension Vocabulary {
    /// Whether this release was built with the value, one of ``known``.
    public var isKnown: Bool {
        Self.known.contains(self)
    }

    public var description: String {
        rawValue
    }
}

/// An answer's value as served, refused only when empty: no list the API
/// publishes holds an empty value, so an empty one is an answer it never built.
func vocabulary<V: Vocabulary>(_ served: String, _ member: String) throws -> V {
    guard !served.isEmpty else {
        throw InternetDataError.unreadable("\(member) \"\"", status: 200)
    }
    return V(rawValue: served)
}
