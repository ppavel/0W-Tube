import Foundation

/// Нормализация и транслитерация заголовков. В Java эти методы живут в
/// `PeerTubeClient`, а `VideoRanker` вызывает их оттуда; здесь они вынесены в общее
/// место — поведение то же, но без обратной зависимости ранжирования от бэкенда.
enum TitleText {
    private static let translit: [Character: String] = {
        let source = Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")
        let replacements = ["a", "b", "v", "g", "d", "e", "yo", "zh", "z", "i", "y",
                            "k", "l", "m", "n", "o", "p", "r", "s", "t", "u", "f", "kh",
                            "ts", "ch", "sh", "shch", "", "y", "", "e", "yu", "ya"]
        var result: [Character: String] = [:]
        for (index, character) in source.enumerated() { result[character] = replacements[index] }
        return result
    }()

    static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        var result = ""
        result.reserveCapacity(value.count)
        var space = true
        for character in value.lowercased().replacingOccurrences(of: "ё", with: "е") {
            if character.isLetter || character.isNumber {
                result.append(character)
                space = false
            } else if !space {
                result.append(" ")
                space = true
            }
        }
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    static func transliterate(_ value: String?) -> String {
        let normalized = normalize(value)
        var result = ""
        result.reserveCapacity(normalized.count * 2)
        for character in normalized {
            result += translit[character] ?? String(character)
        }
        return normalize(result)
    }

    static func words(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: " ").map(String.init)
    }

    static func editDistance(_ left: [Character], _ right: [Character]) -> Int {
        var left = left
        var right = right
        if left.count < right.count { swap(&left, &right) }
        var previous = Array(0...right.count)
        for i in 1...max(1, left.count) where !left.isEmpty {
            var current = [Int](repeating: 0, count: right.count + 1)
            current[0] = i
            for j in 1...max(1, right.count) where !right.isEmpty {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(min(current[j - 1] + 1, previous[j] + 1), substitution)
            }
            previous = current
        }
        return previous[right.count]
    }

    static func editDistance(_ left: String, _ right: String) -> Int {
        editDistance(Array(left), Array(right))
    }

    /// Совпадение слов с допуском на опечатки транслитерации: короткие слова
    /// сравниваются строго, длинные — с расстоянием редактирования 1–2.
    static func tokenMatches(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        let shortest = min(left.count, right.count)
        if shortest < 5 { return false }
        let allowed = max(left.count, right.count) <= 8 ? 1 : 2
        return editDistance(left, right) <= allowed
    }

    static func isYear(_ value: String) -> Bool {
        guard value.count == 4, let year = Int(value) else { return false }
        return year >= 1900 && year <= 2099
    }
}
