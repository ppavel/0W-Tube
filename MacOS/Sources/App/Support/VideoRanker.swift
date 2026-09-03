import Foundation

/// Быстрое локальное ранжирование по релевантности заголовка. Известное максимальное
/// качество работает разрешающим признаком при равной релевантности, а неизвестное
/// (`0`) всегда уходит в конец.
enum VideoRanker {
    private static let unwanted = ["трейлер", "обзор", "фрагмент", "отрывок", "тизер"]

    /// Сортировка стабильна, поэтому при равенстве сохраняется порядок самого источника.
    static func sort(_ items: [VideoItem], query: String, lowestQualityFirst: Bool = false) -> [VideoItem] {
        var scores: [String: Int] = [:]
        func cachedScore(_ title: String) -> Int {
            if let cached = scores[title] { return cached }
            let calculated = score(title: title, query: query)
            scores[title] = calculated
            return calculated
        }
        return items.enumerated().sorted { left, right in
            let leftScore = cachedScore(left.element.title)
            let rightScore = cachedScore(right.element.title)
            if leftScore != rightScore { return leftScore > rightScore }
            var quality = lowestQualityFirst
                ? compareKnownQuality(left.element.maxWidth, right.element.maxWidth)
                : compare(right.element.maxWidth, left.element.maxWidth)
            if quality != 0 { return quality < 0 }
            quality = lowestQualityFirst
                ? compareKnownQuality(left.element.maxHeight, right.element.maxHeight)
                : compare(right.element.maxHeight, left.element.maxHeight)
            if quality != 0 { return quality < 0 }
            return left.offset < right.offset
        }.map { $0.element }
    }

    static func score(title: String, query: String) -> Int {
        let normalizedTitle = TitleText.normalize(title)
        let normalizedQuery = TitleText.normalize(query)
        if normalizedTitle.isEmpty || normalizedQuery.isEmpty { return 0 }
        let nativeScore = scoreNormalized(normalizedTitle, normalizedQuery)
        let latinTitle = TitleText.transliterate(normalizedTitle)
        let latinQuery = TitleText.transliterate(normalizedQuery)
        var latinScore = scoreNormalized(latinTitle, latinQuery)
        if fuzzyPhrase(latinTitle, latinQuery) {
            let sameLength = TitleText.words(latinTitle).count == TitleText.words(latinQuery).count
            latinScore = max(latinScore, sameLength ? 90_000 : 34_000)
        }
        return max(nativeScore, latinScore)
    }

    private static func scoreNormalized(_ normalizedTitle: String, _ normalizedQuery: String) -> Int {
        var score = 0
        if normalizedTitle == normalizedQuery { score += 100_000 }
        else if normalizedTitle.hasPrefix(normalizedQuery) { score += 35_000 }
        else if normalizedTitle.contains(normalizedQuery) { score += 25_000 }

        let queryWords = TitleText.words(normalizedQuery)
        let titleWords = TitleText.words(normalizedTitle)
        let titleSet = Set(titleWords)
        let matched = queryWords.filter { titleSet.contains($0) }.count
        score += matched * 5_000
        if matched == queryWords.count { score += 10_000 }
        score -= max(0, titleWords.count - queryWords.count) * 60
        for word in unwanted where normalizedTitle.contains(word) && !normalizedQuery.contains(word) {
            score -= 3_000
        }
        return score
    }

    private static func fuzzyPhrase(_ title: String, _ query: String) -> Bool {
        let titleWords = TitleText.words(title)
        let queryWords = TitleText.words(query)
        if queryWords.isEmpty || queryWords.count > titleWords.count { return false }
        for (index, word) in queryWords.enumerated() {
            if !TitleText.tokenMatches(word, titleWords[index]) { return false }
        }
        return true
    }

    private static func compare(_ left: Int, _ right: Int) -> Int {
        left == right ? 0 : (left < right ? -1 : 1)
    }

    private static func compareKnownQuality(_ left: Int, _ right: Int) -> Int {
        if left == 0 { return right == 0 ? 0 : 1 }
        if right == 0 { return -1 }
        return compare(left, right)
    }
}
