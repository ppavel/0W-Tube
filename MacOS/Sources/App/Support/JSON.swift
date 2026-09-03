import Foundation

/// Минимальное read-only повторение той части API `org.json`, под которую написаны
/// Java-клиенты: `opt*` никогда не бросает исключение и приводит типы так же, как
/// оригинал. Благодаря этому парсеры бэкендов переносятся построчно и остаются
/// сверяемыми с Java-исходником.
struct JSON {
    let raw: Any?

    init(_ raw: Any?) {
        if raw is NSNull { self.raw = nil } else { self.raw = raw }
    }

    init(parsing text: String) throws {
        let data = Data(text.utf8)
        self.init(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    var isMissing: Bool { raw == nil }

    var dictionary: [String: Any]? { raw as? [String: Any] }
    var arrayValue: [Any]? { raw as? [Any] }

    /// Порядок ключей у `JSONSerialization` не сохраняется. Java-код полагается на
    /// перебор ключей только там, где важен не порядок, а сам набор (`files`,
    /// `video_balancer`), поэтому ключи отдаются отсортированными — это делает
    /// результат детерминированным между запусками.
    var keys: [String] { dictionary.map { $0.keys.sorted() } ?? [] }

    func has(_ key: String) -> Bool { dictionary?[key] != nil }

    subscript(key: String) -> JSON { JSON(dictionary?[key]) }
    subscript(index: Int) -> JSON {
        guard let values = arrayValue, index >= 0, index < values.count else { return JSON(nil) }
        return JSON(values[index])
    }

    /// `optJSONObject`: значение, только если это объект.
    func object(_ key: String) -> JSON? {
        guard let value = dictionary?[key], value is [String: Any] else { return nil }
        return JSON(value)
    }

    /// `optJSONArray`: элементы массива, обёрнутые в `JSON`.
    func array(_ key: String) -> [JSON]? {
        guard let values = dictionary?[key] as? [Any] else { return nil }
        return values.map(JSON.init)
    }

    var elements: [JSON] { (arrayValue ?? []).map(JSON.init) }

    var objectValue: JSON? { raw is [String: Any] ? self : nil }

    // MARK: - Скаляры с приведением типов, как в org.json

    func string(_ key: String, _ fallback: String = "") -> String {
        JSON(dictionary?[key]).stringValue ?? fallback
    }

    func int(_ key: String, _ fallback: Int = 0) -> Int {
        JSON(dictionary?[key]).intValue ?? fallback
    }

    func long(_ key: String, _ fallback: Int = 0) -> Int {
        JSON(dictionary?[key]).intValue ?? fallback
    }

    func double(_ key: String, _ fallback: Double = 0) -> Double {
        JSON(dictionary?[key]).doubleValue ?? fallback
    }

    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        JSON(dictionary?[key]).boolValue ?? fallback
    }

    var stringValue: String? {
        switch raw {
        case let value as String: return value
        case let value as NSNumber:
            // org.json печатает целые без дробной части.
            if CFNumberIsFloatType(value) { return "\(value.doubleValue)" }
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
            return "\(value.int64Value)"
        default: return nil
        }
    }

    var intValue: Int? {
        switch raw {
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
            return Int(value.int64Value)
        case let value as String:
            if let parsed = Int(value.trimmingCharacters(in: .whitespaces)) { return parsed }
            return Double(value).map { Int($0) }
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch raw {
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
            return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch raw {
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue }
            return value.int64Value != 0
        case let value as String:
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }
}
