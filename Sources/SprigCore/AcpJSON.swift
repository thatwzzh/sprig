import Foundation

/// ACP 帧用的 JSON。只覆盖协议里出现的形状：对象、数组、字符串、数字、布尔、null。
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var object: [String: JSONValue]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }

    var array: [JSONValue]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    /// JSON-RPC id。数字和字符串都要原样回写，不能把字符串 id 收成 Int。
    var rpcID: JSONValue? {
        switch self {
        case .number, .string:
            return self
        default:
            return nil
        }
    }

    var canonicalID: String? {
        switch self {
        case .number(let value):
            if value.rounded() == value, value <= Double(Int.max), value >= Double(Int.min) {
                return String(Int(value))
            }
            return String(value)
        case .string(let value):
            return "s:" + value
        default:
            return nil
        }
    }

    static func parse(line: String) -> JSONValue? {
        guard let data = line.data(using: .utf8) else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> JSONValue? {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return from(raw)
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: toObject(), options: [])
    }

    func toObject() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            if value.rounded() == value, value <= Double(Int.max), value >= Double(Int.min) {
                return Int(value)
            }
            return value
        case .string(let value):
            return value
        case .array(let items):
            return items.map { $0.toObject() }
        case .object(let fields):
            return fields.mapValues { $0.toObject() }
        }
    }

    private static func from(_ raw: Any) -> JSONValue {
        if raw is NSNull { return .null }
        if let value = raw as? String { return .string(value) }
        if let value = raw as? NSNumber {
            // 布尔也是 NSNumber。先看 CFBoolean，避免把 1 收成 true。
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        }
        if let value = raw as? [Any] {
            return .array(value.map(from))
        }
        if let value = raw as? [String: Any] {
            return .object(value.mapValues(from))
        }
        return .null
    }
}
