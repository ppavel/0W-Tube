import Foundation

/// Анонимный клиент OK: публичный компонент поиска видео и метаданные плеера.
/// Порядок получения потока повторяет экстрактор Odnoklassniki из yt-dlp —
/// сначала встроенные параметры плеера, затем эндпоинт метаданных и мобильная страница.
enum OkClient {
    private static let limit = 12
    private static let maxSearchBytes = 2 * 1024 * 1024
    private static let maxPlayerBytes = 1024 * 1024
    static let referer = "https://ok.ru/"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

    struct PlayerData {
        let id: String
        let metadata: JSON?
        let externalUrl: String?
        let mobileUrl: String?
    }

    static func search(query: String, minWidth: Int) async throws -> [VideoItem] {
        let address = "https://ok.ru/video/search?st.cmd=anonymVideo&st.ft=search"
            + "&st.gsq=\(Url.encode(query))&st.m=SEARCH"
        let result = try parseSearchResults(try await get(address, limit: maxSearchBytes))
        if minWidth <= 0 || result.isEmpty { return result }
        return result.filter { $0.maxWidth >= minWidth }
    }

    static func parseSearchResults(_ html: String) throws -> [VideoItem] {
        guard let component = html.range(of: "<video-search-result"),
              let tagEnd = html[component.lowerBound...].firstIndex(of: ">") else {
            throw HttpError.message("OK не отдал результаты поиска")
        }
        let tag = String(html[component.lowerBound...tagEnd])
        guard let encoded = attribute(tag, "data-props"), !encoded.isEmpty else {
            throw HttpError.message("OK не отдал данные результатов")
        }

        let props = try JSON(parsing: decodeHtml(encoded))
        guard let list = props.object("videos")?.array("list") else { return [] }

        var result: [VideoItem] = []
        var seen = Set<String>()
        for card in list {
            if result.count >= limit { break }
            guard let movie = card.object("movie"), !movie.bool("blocked") else { continue }
            // Ролики внешних провайдеров (YouTube и прочие) приложение не воспроизводит.
            guard isNativeProvider(movie.string("provider")) else { continue }

            let id = movie.string("id")
            guard isVideoId(id), seen.insert(id).inserted else { continue }
            var title = decodeHtml(card.string("name", movie.string("title")))
            if title.isEmpty { title = "Видео OK" }
            var thumbnail = decodeHtml(card.string("imageUrl"))
            if thumbnail.isEmpty, let thumbnails = movie.object("thumbnail") {
                let big = thumbnails.string("big")
                thumbnail = decodeHtml(big.isEmpty ? thumbnails.string("small") : big)
            }
            let width = max(0, movie.int("width"))
            let height = max(0, movie.int("height"))
            result.append(VideoItem(source: VideoSource.ok,
                                    title: title,
                                    thumbnail: thumbnail,
                                    playUrl: "https://ok.ru/videoembed/\(id)",
                                    pageUrl: "https://ok.ru/video/\(id)",
                                    durationMs: max(0, movie.long("duration")),
                                    maxWidth: width > 0 && height > 0 ? width : 0,
                                    maxHeight: width > 0 && height > 0 ? height : 0))
        }
        return result
    }

    static func loadPlayerData(_ url: String) async throws -> PlayerData {
        let id = try findVideoId(url)
        let desktopError: Error
        do {
            let html = try await get("https://ok.ru/videoembed/\(id)", limit: maxPlayerBytes)
            return try await parseDesktopPlayer(id: id, html: html)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            desktopError = error
        }

        do {
            let html = try await get("https://m.ok.ru/video/\(id)", limit: maxPlayerBytes)
            return try await parseMobilePlayer(id: id, html: html)
        } catch {
            throw desktopError
        }
    }

    static func cdnText(_ address: String) async throws -> String {
        try await get(address, limit: maxPlayerBytes)
    }

    static func parseDesktopPlayer(id: String, html: String) async throws -> PlayerData {
        let error = textByClass(html, "vp_video_stub_txt")
        if !error.isEmpty { throw HttpError.message("Видео OK недоступно: " + error) }
        if html.contains(">Access to this video is restricted</div>") {
            throw HttpError.message("Видео OK требует авторизацию")
        }

        let player = try playerOptions(html, id: id)
        if player.bool("isExternalPlayer"), let external = Url.http(player.string("url")) {
            return PlayerData(id: id, metadata: nil, externalUrl: external, mobileUrl: nil)
        }

        guard let flashvars = player.object("flashvars") else {
            throw HttpError.message("OK не отдал параметры плеера")
        }
        var metadata: JSON?
        if let inline = flashvars.object("metadata") {
            metadata = inline
        } else {
            let value = flashvars.string("metadata")
            if !value.isEmpty && value != "null" { metadata = try JSON(parsing: value) }
        }
        if metadata == nil {
            let raw = flashvars.string("metadataUrl")
            if raw.isEmpty { throw HttpError.message("OK не отдал метаданные ролика") }
            // `removingPercentEncoding` не трогает литеральные `+`, как и
            // `urllib.parse.unquote` в yt-dlp; в Java для этого нужен обходной приём.
            guard let metadataUrl = Url.http(raw.removingPercentEncoding ?? raw) else {
                throw HttpError.message("OK отдал неверный URL метаданных")
            }
            let location = flashvars.string("location")
            let body = location.isEmpty ? "" : "st.location=\(Url.encode(location))"
            metadata = try JSON(parsing: try await post(metadataUrl, body: body, limit: maxPlayerBytes))
        }
        return PlayerData(id: id, metadata: metadata, externalUrl: nil, mobileUrl: nil)
    }

    static func parseMobilePlayer(id: String, html: String) async throws -> PlayerData {
        let emptyMarker = "<div class=\"empty\">"
        if let empty = html.range(of: emptyMarker),
           let end = html.range(of: "</div>", range: empty.upperBound..<html.endIndex)?.lowerBound {
            let error = stripTags(String(html[empty.upperBound..<end]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !error.isEmpty { throw HttpError.message("Видео OK недоступно: " + decodeHtml(error)) }
        }

        guard let encoded = firstAttribute(html, "data-video"), !encoded.isEmpty else {
            throw HttpError.message("OK не отдал мобильный поток")
        }
        let data = try JSON(parsing: decodeHtml(encoded))
        guard var stream = Url.http(data.string("videoSrc")) else {
            throw HttpError.message("OK не отдал мобильный поток")
        }
        var options = baseOptions()
        options.limit = maxPlayerBytes
        if let resolved = try? await Http.resolveRedirects(stream, options) { stream = resolved }
        return PlayerData(id: id, metadata: nil, externalUrl: nil, mobileUrl: stream)
    }

    static func isOkUrl(_ url: String?) -> Bool {
        guard let url else { return false }
        let value = url.lowercased()
        let hosts = ["://ok.ru/", "://www.ok.ru/", "://m.ok.ru/", "://mobile.ok.ru/",
                     "://odnoklassniki.ru/", "://www.odnoklassniki.ru/",
                     "://m.odnoklassniki.ru/", "://mobile.odnoklassniki.ru/"]
        guard hosts.contains(where: value.contains) else { return false }
        return (try? findVideoId(url)) != nil
    }

    static func findVideoId(_ url: String?) throws -> String {
        guard let url else { throw HttpError.message("Не найден ID OK") }
        let markers = ["/videoembed/", "/video/", "/web-api/video/moviePlayer/", "/live/", "st.mvId="]
        for marker in markers {
            guard let range = url.range(of: marker) else { continue }
            var candidate = ""
            var digit = false
            for character in url[range.upperBound...] {
                if character >= "0" && character <= "9" {
                    digit = true
                    candidate.append(character)
                } else if character == "-" {
                    candidate.append(character)
                } else {
                    break
                }
            }
            if digit && isVideoId(candidate) { return candidate }
        }
        throw HttpError.message("Не найден ID OK")
    }

    // MARK: - Разбор HTML

    static func decodeHtml(_ value: String?) -> String {
        guard let value else { return "" }
        guard value.contains("&") else { return value }
        var result = ""
        result.reserveCapacity(value.count)
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let current = value[cursor]
            if current != "&" {
                result.append(current)
                cursor = value.index(after: cursor)
                continue
            }
            let searchEnd = value.index(cursor, offsetBy: 13, limitedBy: value.endIndex) ?? value.endIndex
            guard let semicolon = value[value.index(after: cursor)..<searchEnd].firstIndex(of: ";") else {
                result.append(current)
                cursor = value.index(after: cursor)
                continue
            }
            let entity = String(value[value.index(after: cursor)..<semicolon])
            if let decoded = decodeEntity(entity) {
                result += decoded
                cursor = value.index(after: semicolon)
            } else {
                result.append(current)
                cursor = value.index(after: cursor)
            }
        }
        return result
    }

    private static func playerOptions(_ html: String, id: String) throws -> JSON {
        var cursor = html.startIndex
        while cursor < html.endIndex {
            guard let at = html.range(of: "data-options=", range: cursor..<html.endIndex) else { break }
            let valueStart = at.upperBound
            guard valueStart < html.endIndex else { break }
            let quote = html[valueStart]
            guard quote == "\"" || quote == "'" else {
                cursor = html.index(after: valueStart)
                continue
            }
            let contentStart = html.index(after: valueStart)
            guard let end = html[contentStart...].firstIndex(of: quote) else { break }
            let decoded = decodeHtml(String(html[contentStart..<end]))
            if decoded.contains(id) { return try JSON(parsing: decoded) }
            cursor = html.index(after: end)
        }
        throw HttpError.message("OK не отдал данные плеера")
    }

    private static func isNativeProvider(_ provider: String) -> Bool {
        if provider.isEmpty { return true }
        let normalized = provider.replacingOccurrences(of: "_", with: "").uppercased()
        return normalized == "UPLOADEDODKL" || normalized == "LIVETVAPP"
    }

    private static func isVideoId(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var digit = false
        for character in value {
            if character >= "0" && character <= "9" { digit = true }
            else if character != "-" { return false }
        }
        return digit
    }

    private static func firstAttribute(_ html: String, _ name: String) -> String? {
        guard let marker = html.range(of: name + "=")?.lowerBound,
              let tagStart = html.range(of: "<", options: .backwards,
                                        range: html.startIndex..<marker)?.lowerBound,
              let tagEnd = html[marker...].firstIndex(of: ">") else { return nil }
        return attribute(String(html[tagStart...tagEnd]), name)
    }

    private static func attribute(_ tag: String, _ name: String) -> String? {
        guard let at = tag.range(of: name + "=") else { return nil }
        let start = at.upperBound
        guard start < tag.endIndex else { return nil }
        let quote = tag[start]
        guard quote == "\"" || quote == "'" else { return nil }
        let contentStart = tag.index(after: start)
        guard let end = tag[contentStart...].firstIndex(of: quote) else { return nil }
        return String(tag[contentStart..<end])
    }

    private static func textByClass(_ html: String, _ className: String) -> String {
        guard let classAt = html.range(of: className)?.lowerBound,
              let start = html[classAt...].firstIndex(of: ">") else { return "" }
        let afterStart = html.index(after: start)
        guard let end = html.range(of: "</", range: afterStart..<html.endIndex)?.lowerBound else { return "" }
        return decodeHtml(stripTags(String(html[afterStart..<end])))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ value: String) -> String {
        var result = ""
        var tag = false
        for character in value {
            if character == "<" { tag = true }
            else if character == ">" { tag = false }
            else if !tag { result.append(character) }
        }
        return result
    }

    private static func decodeEntity(_ entity: String) -> String? {
        switch entity {
        case "quot": return "\""
        case "amp": return "&"
        case "apos", "#39": return "'"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return "\u{00a0}"
        default:
            guard entity.hasPrefix("#") else { return nil }
            let marker: Character? = entity.dropFirst().first
            let hex: Bool = entity.count > 2 && (marker == "x" || marker == "X")
            let digits: Substring = entity.dropFirst(hex ? 2 : 1)
            let radix: Int = hex ? 16 : 10
            guard let code = UInt32(digits, radix: radix),
                  let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
    }

    // MARK: - Сеть

    private static func baseOptions() -> Http.Options {
        var options = Http.Options()
        options.accept = "text/html,application/json,*/*"
        options.acceptLanguage = "ru-RU,ru;q=0.9"
        options.userAgent = userAgent
        options.referer = referer
        options.timeout = 10
        options.errorPrefix = "OK"
        return options
    }

    private static func get(_ address: String, limit: Int) async throws -> String {
        var options = baseOptions()
        options.limit = limit
        return try await Http.text(address, options)
    }

    private static func post(_ address: String, body: String, limit: Int) async throws -> String {
        var options = baseOptions()
        options.method = "POST"
        options.body = Data(body.utf8)
        options.contentType = "application/x-www-form-urlencoded; charset=UTF-8"
        options.limit = limit
        return try await Http.text(address, options)
    }
}
