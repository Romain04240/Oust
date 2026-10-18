import Foundation

/// Une valeur JSON quelconque : les messages JSON-RPC n'ont pas de forme fixe.
///
/// Écrit ici plutôt que de prendre une bibliothèque (RULES.md, règle 12) :
/// six cas suffisent.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
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
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Une valeur encodable, passée par le JSON.
    init(encoding value: some Encodable) throws {
        let data = try JSONEncoder.agent().encode(value)
        self = try JSONDecoder.agent().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var integer: Int64? {
        switch self {
        case .integer(let value): value
        case .number(let value) where value.rounded() == value && abs(value) < 1e15: Int64(value)
        default: nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Sur une ligne, comme l'exige le transport stdio de MCP.
    public func line() -> String {
        let data = (try? JSONEncoder.agent().encode(self)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// Pas de `ExpressibleByNilLiteral` : `valeur == nil` deviendrait ambigu entre
// l'absence et `null`, et un test l'a pris pour `null`.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
