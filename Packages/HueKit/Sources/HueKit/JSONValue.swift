import Foundation

/// A JSON tree. The bridge's resources are kept in this form so that partial
/// updates from the event stream and local optimistic changes merge the same way.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    public init(data: Data) throws {
        self = JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed])
    }

    init(any: Any) {
        switch any {
        case let dict as [String: Any]:
            self = .object(dict.mapValues(JSONValue.init(any:)))
        case let list as [Any]:
            self = .array(list.map(JSONValue.init(any:)))
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        default:
            self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.anyValue)
        case .object(let values): values.mapValues(\.anyValue)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let values) = self { values[key] } else { nil }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var double: Double? { if case .number(let value) = self { value } else { nil } }
    public var int: Int? { double.map { Int($0.rounded()) } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let values) = self { values } else { nil } }

    /// Deep-merges `patch` into this value. Objects merge key by key; anything else is replaced.
    public func merging(_ patch: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let changes) = patch else { return patch }
        for (key, value) in changes {
            base[key] = base[key].map { $0.merging(value) } ?? value
        }
        return .object(base)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral
{
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
