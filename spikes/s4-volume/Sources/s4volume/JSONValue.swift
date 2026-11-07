import Foundation

/// A small JSON tree so every probe can report a value or an error in the same shape.
enum JSONValue: Sendable, Encodable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: any Encoder) throws {
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

    /// Integer from any BinaryInteger, clamped to Int64.
    static func bytes<T: BinaryInteger>(_ value: T) -> JSONValue {
        .int(Int64(clamping: value))
    }

    static func optionalInt(_ value: Int64?) -> JSONValue {
        value.map { .int($0) } ?? .null
    }

    /// Converts a property-list or URLResourceValues value (NSNumber, String, Data, Date, Array, Dictionary).
    init(any value: Any) {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        } else if let string = value as? String {
            self = .string(string)
        } else if let date = value as? Date {
            self = .string(ISO8601DateFormatter().string(from: date))
        } else if let data = value as? Data {
            self = .string("<\(data.count) bytes of data>")
        } else if let array = value as? [Any] {
            self = .array(array.map { JSONValue(any: $0) })
        } else if let dictionary = value as? [String: Any] {
            self = .object(dictionary.mapValues { JSONValue(any: $0) })
        } else {
            self = .string(String(describing: value))
        }
    }

    /// Error as {domain, code, description}, plus the underlying POSIX error when there is one.
    static func error(_ error: any Error) -> JSONValue {
        let ns = error as NSError
        var object: [String: JSONValue] = [
            "domain": .string(ns.domain),
            "code": .int(Int64(ns.code)),
            "description": .string(ns.localizedDescription),
        ]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            object["underlying"] = [
                "domain": .string(underlying.domain),
                "code": .int(Int64(underlying.code)),
                "description": .string(underlying.localizedDescription),
            ]
        }
        return .object(object)
    }

    /// errno as {errno, name, description}.
    static func errno(_ code: Int32) -> JSONValue {
        [
            "errno": .int(Int64(code)),
            "description": .string(String(cString: strerror(code))),
        ]
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// Decimal units (powers of 10), like Finder and Storage settings.
func humanBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
