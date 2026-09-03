import Foundation

/// Анонимный веб-клиент VK Video: тот же поток запросов, что и у публичной страницы
/// поиска `vkvideo.ru`. Аккаунт и постоянный пользовательский токен не нужны —
/// используется короткоживущая анонимная сессия.
enum VkWebClient {
    private static let limit = 12
    private static let maxPages = 4
    private static let clientId = "52461373"
    private static let apiVersion = "5.282"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 Chrome/150.0.0.0 Safari/537.36"

    /// Токен переживает отдельный поиск и обновляется по истечении срока или при
    /// ошибке авторизации (`error_code == 5`).
    private actor TokenStore {
        private var token: String?
        private var expiresAt = 0

        func current() async throws -> String {
            let now = Int(Date().timeIntervalSince1970)
            if let token, now + 60 < expiresAt { return token }
            let root = try await postJson("https://login.vk.com/?act=get_anonym_token",
                                          body: "client_id=\(clientId)")
            guard root.string("type") == "okay", let data = root.object("data") else {
                throw HttpError.message("VK Video не выдал анонимную сессию")
            }
            let value = data.string("access_token")
            if value.isEmpty { throw HttpError.message("VK Video не выдал анонимную сессию") }
            token = value
            expiresAt = data.long("expired_at")
            return value
        }

        func clear() {
            token = nil
            expiresAt = 0
        }
    }

    private static let tokens = TokenStore()

    // MARK: - Поиск

    static func search(query: String, minWidth: Int, thumbnailWidth: Int) async throws -> [VideoItem] {
        var result: [VideoItem] = []
        _ = try await searchPages(query: query, minWidth: minWidth,
                                  thumbnailWidth: thumbnailWidth) { page in
            result.append(contentsOf: page)
            return true
        }
        if minWidth <= 0 || result.isEmpty { return result }
        return try await SearchClient.filterByQuality(result, minWidth: minWidth)
    }

    /// Страницы отдаются по мере готовности, чтобы карточки появлялись до конца пагинации.
    @discardableResult
    static func searchPages(query: String, minWidth: Int, thumbnailWidth: Int,
                            onPage: ([VideoItem]) async -> Bool) async throws -> Int {
        var address = "https://api.vkvideo.ru/method/catalog.getVideoSearchWeb2"
            + "?v=\(apiVersion)&client_id=\(clientId)&count=30"
            + "&q=\(Url.encode(query))&content_type=video"
            + (minWidth > 0 ? "&hd=1" : "")
        var root = try await authorizedJson(address, body: nil)
        var response: JSON? = try unwrapResponse(root)
        var seen = Set<String>()
        var total = 0
        var pages = 0
        var previousNext = ""

        while let current = response, total < limit, pages < maxPages {
            try Task.checkCancellation()
            pages += 1
            let page = parsePage(current, thumbnailWidth: thumbnailWidth,
                                 seen: &seen, limit: limit - total)
            total += page.count
            if !page.isEmpty, await !onPage(page) { break }
            guard let cursor = pageCursor(current), cursor.nextFrom != previousNext,
                  total < limit else { break }
            previousNext = cursor.nextFrom
            let body = "section_id=\(Url.encode(cursor.sectionId))"
                + "&start_from=\(Url.encode(cursor.nextFrom))"
            address = "https://api.vkvideo.ru/method/catalog.getSection"
                + "?v=\(apiVersion)&client_id=\(clientId)"
            root = try await authorizedJson(address, body: body)
            response = try unwrapResponse(root)
        }
        return total
    }

    // MARK: - Метаданные ролика

    static func videoById(_ videoId: String, retryToken: Bool = true) async throws -> JSON {
        let address = "https://api.vk.com/method/video.getByIds"
            + "?v=\(apiVersion)&client_id=\(clientId)"
        let fields = "added,episodes,files,image,is_favorite,subtitles,timeline_thumbs,"
            + "trailer,volume_multiplier"
        let token = try await tokens.current()
        let body = "access_token=\(Url.encode(token))"
            + "&videos=\(Url.encode(videoId))"
            + "&video_fields=\(Url.encode(fields))"
        let root = try await postJson(address, body: body)
        if let error = root.object("error") {
            if retryToken && error.int("error_code") == 5 {
                await tokens.clear()
                return try await videoById(videoId, retryToken: false)
            }
            throw HttpError.message("VK Video: "
                + (error.string("error_msg").isEmpty ? "ошибка получения потока" : error.string("error_msg")))
        }
        guard let video = root.object("response")?.array("items")?.first?.objectValue else {
            throw HttpError.message("VK Video не отдал данные ролика")
        }
        return video
    }

    // MARK: - Сеть

    private static func authorizedJson(_ address: String, body: String?) async throws -> JSON {
        var root = JSON(nil)
        for attempt in 0..<2 {
            let token = "access_token=\(Url.encode(try await tokens.current()))"
            root = body == nil
                ? try await getJson(address + "&" + token)
                : try await postJson(address, body: body! + "&" + token)
            if !isAuthorizationError(root) || attempt == 1 { return root }
            await tokens.clear()
        }
        return root
    }

    static func isAuthorizationError(_ root: JSON) -> Bool {
        guard let error = root.object("error") else { return false }
        if error.int("error_code") == 5 { return true }
        return error.string("error_msg").lowercased().contains("authorization failed")
    }

    private static func unwrapResponse(_ root: JSON) throws -> JSON {
        if let error = root.object("error") {
            let message = error.string("error_msg")
            throw HttpError.message("VK Video: " + (message.isEmpty ? "ошибка поиска" : message))
        }
        guard let response = root.object("response") else {
            throw HttpError.message("VK Video не отдал результаты")
        }
        return response
    }

    private static func baseOptions() -> Http.Options {
        var options = Http.Options()
        options.accept = "application/json,*/*"
        options.acceptLanguage = "ru-RU,ru;q=0.9"
        options.userAgent = userAgent
        options.timeout = 10
        options.errorPrefix = "VK Video"
        return options
    }

    private static func getJson(_ address: String) async throws -> JSON {
        try await Http.json(address, baseOptions())
    }

    private static func postJson(_ address: String, body: String) async throws -> JSON {
        var options = baseOptions()
        options.method = "POST"
        options.body = Data(body.utf8)
        options.contentType = "application/x-www-form-urlencoded; charset=UTF-8"
        options.origin = "https://vkvideo.ru"
        options.referer = "https://vkvideo.ru/"
        return try await Http.json(address, options)
    }

    // MARK: - Разбор

    private struct PageCursor {
        let sectionId: String
        let nextFrom: String
    }

    private static func parsePage(_ response: JSON, thumbnailWidth: Int,
                                  seen: inout Set<String>, limit: Int) -> [VideoItem] {
        var videos: [String: JSON] = [:]
        var insertionOrder: [String] = []
        if let catalogVideos = response.array("catalog_videos") {
            for wrapper in catalogVideos {
                guard let video = wrapper.object("video") else { continue }
                let id = key(video)
                if videos[id] == nil { insertionOrder.append(id) }
                videos[id] = video
            }
        }

        // Порядок выдачи задают блоки каталога; всё, чего в них нет, добавляется следом.
        var orderedIds: [String] = []
        var known = Set<String>()
        func append(_ id: String) {
            if !id.isEmpty && known.insert(id).inserted { orderedIds.append(id) }
        }
        if let sections = response.object("catalog")?.array("sections") {
            for section in sections { collectOrderedIds(section, append) }
        }
        if let section = response.object("section") { collectOrderedIds(section, append) }
        for id in insertionOrder { append(id) }

        var result: [VideoItem] = []
        for id in orderedIds {
            guard let video = videos[id], seen.insert(id).inserted else { continue }
            let page = "https://vkvideo.ru/video" + VkVideoId.fromVideo(video)
            let title = video.string("title")
            let dimensions = maxAvailableDimensions(video)
            result.append(VideoItem(source: VideoSource.vk,
                                    title: title.isEmpty ? "Видео VK" : title,
                                    thumbnail: bestImage(video.array("image"), targetWidth: thumbnailWidth),
                                    playUrl: page,
                                    pageUrl: page,
                                    durationMs: video.long("duration") * 1000,
                                    maxWidth: dimensions.0,
                                    maxHeight: dimensions.1))
            if result.count >= limit { break }
        }
        return result
    }

    private static func collectOrderedIds(_ section: JSON, _ append: (String) -> Void) {
        guard let blocks = section.array("blocks") else { return }
        for block in blocks {
            guard let ids = block.array("videos_ids") else { continue }
            for id in ids { append(id.stringValue ?? "") }
        }
    }

    private static func pageCursor(_ response: JSON) -> PageCursor? {
        var section = response.object("section")
        if section == nil {
            section = response.object("catalog")?.array("sections")?.first?.objectValue
        }
        guard let section else { return nil }
        let sectionId = section.string("id")
        let nextFrom = section.string("next_from")
        return sectionId.isEmpty || nextFrom.isEmpty
            ? nil : PageCursor(sectionId: sectionId, nextFrom: nextFrom)
    }

    private static func key(_ video: JSON) -> String {
        "\(video.long("owner_id"))_\(video.long("id"))"
    }

    /// Ключи `mp4_<height>` надёжнее полей `width`/`height`, которые VK часто занижает.
    private static func maxAvailableDimensions(_ video: JSON) -> (Int, Int) {
        var bestHeight = 0
        if let files = video.object("files") {
            for key in files.keys where key.hasPrefix("mp4_") {
                let url = files.string(key)
                guard url.hasPrefix("http") || url.hasPrefix("//") else { continue }
                if let height = Int(key.dropFirst(4)) { bestHeight = max(bestHeight, height) }
            }
        }
        if bestHeight > 0 { return (standardWidth(bestHeight), bestHeight) }
        return (max(0, video.int("width")), max(0, video.int("height")))
    }

    private static func standardWidth(_ height: Int) -> Int {
        switch height {
        case 144: return 256
        case 240: return 426
        case 360: return 640
        case 480: return 854
        case 720: return 1280
        case 1080: return 1920
        case 1440: return 2560
        case 2160: return 3840
        default: return Int((Double(height) * 16.0 / 9.0).rounded())
        }
    }

    /// Наименьшая картинка, покрывающая ширину карточки; иначе — самая большая.
    private static func bestImage(_ images: [JSON]?, targetWidth: Int) -> String {
        guard let images else { return "" }
        var smallestSuitable = ""
        var smallestSuitableWidth = Int.max
        var largestFallback = ""
        var largestFallbackWidth = 0
        for image in images {
            let width = image.int("width")
            let url = image.string("url")
            guard !url.isEmpty, width > 0 else { continue }
            if width > largestFallbackWidth {
                largestFallbackWidth = width
                largestFallback = url
            }
            if width >= targetWidth && width < smallestSuitableWidth {
                smallestSuitableWidth = width
                smallestSuitable = url
            }
        }
        return smallestSuitable.isEmpty ? largestFallback : smallestSuitable
    }
}
