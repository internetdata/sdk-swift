/// One JSON value from a database's sample rows.
///
/// The sample rows are whatever that database's columns happen to be, so they
/// cannot be a fixed Swift type. This is the smallest honest representation:
/// concrete enough to switch over, and `Codable` so a row can be re-encoded or
/// decoded straight into a type of your own.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    public var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value.rounded())
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    // The generated sample rows arrive as OpenAPIRuntime's loosely typed
    // containers, whose leaves are exactly the six JSON kinds below.
    init(_ any: (any Sendable)?) {
        switch any {
        case .none: self = .null
        case .some(let value as Bool): self = .bool(value)
        case .some(let value as Int): self = .int(value)
        case .some(let value as Double): self = .double(value)
        case .some(let value as String): self = .string(value)
        case .some(let value as [(any Sendable)?]): self = .array(value.map(JSONValue.init))
        case .some(let value as [String: (any Sendable)?]):
            self = .object(value.mapValues(JSONValue.init))
        default: self = .null
        }
    }
}
