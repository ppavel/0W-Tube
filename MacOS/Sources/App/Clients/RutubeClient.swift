import Foundation

/// Поиск по публичному эндпоинту RUTUBE. Разбор потока живёт в `StreamResolver`:
/// карточка несёт только адрес плеера, который резолвится перед запуском.
enum RutubeClient {
    private static let limit = 12
    private static let userAgent = "0W-Tube/0.7.3 macOS"

    static func search(query: String, minWidth: Int) async throws -> [VideoItem] {
        let address = "https://rutube.ru/api/search/video/?query=\(Url.encode(query))&page=1"
        var options = Http.Options()
        options.accept = "application/json"
        options.userAgent = userAgent
        options.timeout = 7
        options.errorPrefix = "RUTUBE"
        let root = try await Http.json(address, options)

        guard let items = root.array("results") else { return [] }
        var result: [VideoItem] = []
        for item in items.prefix(limit) {
            let id = item.string("id")
            let page = nonEmpty(item.string("video_url")) ?? "https://rutube.ru/video/\(id)/"
            var embed = nonEmpty(item.string("embed_url")) ?? "https://rutube.ru/play/embed/\(id)"
            embed = copyQueryParameter(from: page, to: embed, name: "p")
            result.append(VideoItem(source: VideoSource.rutube,
                                    title: nonEmpty(item.string("title")) ?? "Без названия",
                                    thumbnail: item.string("thumbnail_url"),
                                    playUrl: embed,
                                    pageUrl: page,
                                    durationMs: item.int("duration") * 1000))
        }
        if minWidth <= 0 || result.isEmpty { return result }
        return try await SearchClient.filterByQuality(result, minWidth: minWidth)
    }

    /// Приватные ролики отдают ключ `p` только на странице; для плеера его нужно перенести.
    private static func copyQueryParameter(from source: String, to target: String, name: String) -> String {
        guard let value = Url.queryParameter(source, name), !value.isEmpty,
              Url.queryParameter(target, name) == nil,
              var components = URLComponents(string: target) else { return target }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.string ?? target
    }

    private static func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }
}
