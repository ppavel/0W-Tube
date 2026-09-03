import Foundation

/// Анонимный клиент Дзена: публичный JSON-поиск с откатом на серверный HTML.
/// Аккаунт и WebView не нужны, хранятся только анонимные cookie сессии.
enum DzenClient {
    private static let limit = 12
    private static let maxPages = 3
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

    /// Свои cookie, а не общий стор URLSession: Java-клиент так же ведёт их вручную,
    /// и это не даёт анонимной сессии Дзена смешаться с запросами других бэкендов.
    private actor CookieJar {
        private var names: [String] = []
        private var values: [String: String] = [:]

        func header() -> String {
            names.compactMap { name in values[name].map { "\(name)=\($0)" } }.joined(separator: "; ")
        }

        func remember(_ cookies: [(name: String, value: String)]) {
            for cookie in cookies {
                if values[cookie.name] == nil { names.append(cookie.name) }
                values[cookie.name] = cookie.value
            }
        }
    }

    private static let cookies = CookieJar()

    static func search(query: String, minWidth: Int) async throws -> [VideoItem] {
        var result: [VideoItem] = []
        _ = try await searchPages(query: query) { page in
            result.append(contentsOf: page)
            return true
        }
        if minWidth <= 0 || result.isEmpty { return result }

        // Часть карточек приходит уже с разрешением — их фильтруем без сетевых проверок,
        // и только неизвестные догружаем через резолвер.
        var filtered: [VideoItem] = []
        var unknown: [VideoItem] = []
        for item in result {
            if item.maxWidth == 0 { unknown.append(item) }
            else if item.maxWidth >= minWidth { filtered.append(item) }
        }
        filtered += try await SearchClient.filterByQuality(unknown, minWidth: minWidth, maxParallelRequests: 2)
        return filtered
    }

    @discardableResult
    static func searchPages(query: String, onPage: ([VideoItem]) async -> Bool) async throws -> Int {
        do {
            let count = try await searchJsonPages(query: query, onPage: onPage)
            if count > 0 { return count }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // JSON-эндпоинт периодически закрывается; ниже идёт разбор обычной страницы.
        }
        let address = "https://dzen.ru/search?query=\(Url.encode(query))&type_filter=video"
        let fallback = parseCards(try await page(address))
        if !fallback.isEmpty { _ = await onPage(fallback) }
        return fallback.count
    }

    private static func searchJsonPages(query: String, onPage: ([VideoItem]) async -> Bool) async throws -> Int {
        var address = "https://dzen.ru/api/web/v1/zen-search"
            + "?country_code=ru&forced_request_type=long_video_search"
            + "&query=\(Url.encode(query))&clid=1400&type_filter=video&lang=ru"
        var seen = Set<String>()
        var total = 0
        for _ in 0..<maxPages {
            if total >= limit { break }
            try Task.checkCancellation()
            let response: JSON
            do {
                response = try await jsonPage(address)
            } catch {
                if total > 0 { return total }
                throw error
            }
            let feed = response.object("feedData") ?? response
            let page = await parseJsonItems(feed.array("items"), seen: &seen, limit: limit - total)
            total += page.count
            if !page.isEmpty, await !onPage(page) { break }

            let next = feed.object("more")?.string("link") ?? ""
            if next.isEmpty || next == address { break }
            address = next
        }
        return total
    }

    private static func parseJsonItems(_ items: [JSON]?, seen: inout Set<String>, limit: Int) async -> [VideoItem] {
        var result: [VideoItem] = []
        guard let items, limit > 0 else { return result }
        for item in items {
            if result.count >= limit { break }
            guard let video = item.object("video") else { continue }
            let id = videoId(item.string("link"))
            guard !id.isEmpty, seen.insert(id).inserted else { continue }

            let page = "https://dzen.ru/video/watch/\(id)"
            let size = dimensions(video)
            // Поисковая выдача уже содержит адреса потоков: кладём их в кэш резолвера,
            // чтобы открытие ролика не требовало повторной загрузки страницы.
            await StreamResolver.cacheDzen(id: id, video: video, maxWidth: size.0, maxHeight: size.1)
            let title = item.string("title")
            result.append(VideoItem(source: VideoSource.dzen,
                                    title: title.isEmpty ? "Видео Дзен" : title,
                                    thumbnail: thumbnail(item.object("image")),
                                    playUrl: page,
                                    pageUrl: page,
                                    durationMs: video.long("duration") * 1000,
                                    maxWidth: size.0,
                                    maxHeight: size.1))
        }
        return result
    }

    private static func videoId(_ link: String) -> String {
        let marker = "/video/watch/"
        guard let range = link.range(of: marker) else { return "" }
        let tail = link[range.upperBound...]
        return String(tail.prefix { isIdChar($0) })
    }

    private static func thumbnail(_ image: JSON?) -> String {
        guard let image else { return "" }
        let direct = image.string("url")
        if !direct.isEmpty { return direct }
        let template = image.string("urlTemplate")
        let namespace = image.string("namespace")
        if template.isEmpty || namespace.isEmpty { return "" }
        let size = image.string("sizeName").isEmpty ? "scale_1200" : image.string("sizeName")
        return template.replacingOccurrences(of: "{namespace}", with: namespace)
            .replacingOccurrences(of: "{size}", with: size)
    }

    static func dimensions(_ video: JSON) -> (Int, Int) {
        var bestWidth = video.int("width")
        var bestHeight = video.int("height")
        if let resolutions = video.array("resolutions") {
            for resolution in resolutions {
                let width = resolution.int("width")
                let height = resolution.int("height")
                if width > bestWidth {
                    bestWidth = width
                    bestHeight = height
                }
            }
        }
        return (bestWidth, bestHeight)
    }

    // MARK: - Сеть

    private static func baseOptions(accept: String) async -> Http.Options {
        var options = Http.Options()
        options.accept = accept
        options.userAgent = userAgent
        options.timeout = 9
        options.followRedirects = false
        options.errorPrefix = "Дзен"
        options.cookie = await cookies.header()
        return options
    }

    private static func jsonPage(_ address: String) async throws -> JSON {
        for _ in 0..<3 {
            try Task.checkCancellation()
            let response = try await Http.request(address, await baseOptions(accept: "application/json"))
            await cookies.remember(response.setCookies)
            if (300..<400).contains(response.statusCode) { continue }
            guard (200..<300).contains(response.statusCode) else {
                throw HttpError.status("Дзен", response.statusCode)
            }
            return try JSON(parsing: response.text)
        }
        throw HttpError.message("Дзен не создал анонимную сессию")
    }

    /// Свежая анонимная сессия Дзена обычно отвечает двумя SSO-редиректами. Они лишь
    /// выставляют анонимные cookie, поэтому достаточно повторить исходный URL — не
    /// открывая SSO-страницу и не выполняя JavaScript.
    static func page(_ address: String) async throws -> String {
        for _ in 0..<4 {
            try Task.checkCancellation()
            let options = await baseOptions(accept: "text/html,application/xhtml+xml,*/*")
            let response = try await Http.request(address, options)
            await cookies.remember(response.setCookies)
            if (300..<400).contains(response.statusCode) { continue }
            guard (200..<300).contains(response.statusCode) else {
                throw HttpError.status("Дзен", response.statusCode)
            }
            let body = response.text
            if body.contains("data-card-type=\"card-video\"") || body.contains("\"videoMetaResponse\"") {
                return body
            }
            // Cookie могли истечь между запросами: повторяем ту же страницу.
            if !body.contains("sso.dzen.ru") && !body.contains("sso.passport.yandex.ru") { return body }
        }
        throw HttpError.message("Дзен не создал анонимную сессию")
    }

    // MARK: - Разбор HTML

    private static func parseCards(_ html: String) -> [VideoItem] {
        var result: [VideoItem] = []
        var seen = Set<String>()
        let marker = "https://dzen.ru/video/watch/"
        var cursor = html.startIndex
        while result.count < limit {
            guard let link = html.range(of: marker, range: cursor..<html.endIndex) else { break }
            let id = String(html[link.upperBound...].prefix { isIdChar($0) })
            cursor = html.index(link.upperBound, offsetBy: id.count, limitedBy: html.endIndex) ?? html.endIndex
            guard !id.isEmpty, seen.insert(id).inserted else { continue }

            guard let articleStart = html.range(of: "<article", options: .backwards,
                                                range: html.startIndex..<link.lowerBound)?.lowerBound,
                  let articleEnd = html.range(of: "</article>", range: link.lowerBound..<html.endIndex)?.lowerBound
            else { continue }
            let card = String(html[articleStart..<articleEnd])
            if card.count > 80_000 { continue }

            var title = textAfter(card, "data-testid=\"card-part-title\">")
            if title.isEmpty { title = attributeNear(card, "floor-card-video-wrapper-link", "aria-label") }
            if title.isEmpty { title = "Видео Дзен" }
            let durationMs = parseDuration(textAfter(card, "aria-label=\"Общая длительность видео\">")) * 1000
            let thumbnail = between(card, "background-image:url(", ")")
            let page = marker + id
            result.append(VideoItem(source: VideoSource.dzen,
                                    title: decode(title),
                                    thumbnail: decode(thumbnail),
                                    playUrl: page,
                                    pageUrl: page,
                                    durationMs: durationMs))
        }
        return result
    }

    static func isIdChar(_ value: Character) -> Bool {
        (value >= "a" && value <= "z") || (value >= "A" && value <= "Z")
            || (value >= "0" && value <= "9") || value == "-" || value == "_"
    }

    private static func textAfter(_ value: String, _ marker: String) -> String {
        guard let start = value.range(of: marker)?.upperBound,
              let end = value[start...].firstIndex(of: "<") else { return "" }
        return String(value[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attributeNear(_ value: String, _ marker: String, _ attribute: String) -> String {
        guard let markerAt = value.range(of: marker)?.lowerBound,
              let tagStart = value.range(of: "<", options: .backwards,
                                         range: value.startIndex..<markerAt)?.lowerBound,
              let tagEnd = value[markerAt...].firstIndex(of: ">") else { return "" }
        return between(String(value[tagStart...tagEnd]), attribute + "=\"", "\"")
    }

    private static func between(_ value: String, _ before: String, _ after: String) -> String {
        guard let start = value.range(of: before)?.upperBound,
              let end = value.range(of: after, range: start..<value.endIndex)?.lowerBound else { return "" }
        return String(value[start..<end])
    }

    private static func parseDuration(_ value: String) -> Int {
        var seconds = 0
        for part in value.split(separator: ":") {
            guard let number = Int(part.trimmingCharacters(in: .whitespaces)) else { return 0 }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
