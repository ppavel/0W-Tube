import Foundation

/// Единая точка получения потока. `VideoItem.playUrl` — не ссылка на видео, а адрес
/// резолвера; бэкенд определяется по его виду. Потоки всегда добываются заново прямо
/// перед воспроизведением, потому что подписанные CDN-ссылки быстро протухают,
/// а результаты держатся в кэше не дольше десяти минут.
enum StreamResolver {
    private static let cacheInterval: TimeInterval = 10 * 60
    private static let maxDzenStreams = 36

    private actor PlaybackCache {
        private var values: [String: PlaybackInfo] = [:]

        func get(_ key: String) -> PlaybackInfo? {
            guard let value = values[key],
                  Date().timeIntervalSince(value.loadedAt) < cacheInterval else { return nil }
            return value
        }

        func put(_ key: String, _ value: PlaybackInfo) { values[key] = value }
    }

    private actor DzenStreamCache {
        private var values: [String: DzenStreams] = [:]

        func get(_ key: String) -> DzenStreams? {
            guard let value = values[key],
                  Date().timeIntervalSince(value.loadedAt) < cacheInterval else { return nil }
            return value
        }

        func put(_ key: String, _ value: DzenStreams) {
            let now = Date()
            for (entry, streams) in values where now.timeIntervalSince(streams.loadedAt) >= cacheInterval {
                values.removeValue(forKey: entry)
            }
            if values.count >= maxDzenStreams,
               let oldest = values.min(by: { $0.value.loadedAt < $1.value.loadedAt })?.key {
                values.removeValue(forKey: oldest)
            }
            values[key] = value
        }
    }

    private static let cache = PlaybackCache()
    private static let dzenStreams = DzenStreamCache()

    // MARK: - Точки входа

    static func resolve(_ resolverUrl: String) async throws -> String {
        try await resolveForPlayback(resolverUrl, audioOnly: false).streamUrl
    }

    static func resolveForPlayback(_ resolverUrl: String, audioOnly: Bool) async throws -> PlaybackInfo {
        if PeerTubeClient.isApiUrl(resolverUrl) {
            return try await PeerTubeClient.resolve(resolverUrl, audioOnly: audioOnly)
        }
        if resolverUrl.contains("dzen.ru/video/") || resolverUrl.contains("zen.yandex.ru/video/") {
            return try await inspectDzen(resolverUrl, forPlayback: true, audioOnly: audioOnly)
        }
        if resolverUrl.contains("vkvideo.ru/") || resolverUrl.contains("vk.com/video") {
            return try await inspectVk(resolverUrl, audioOnly: audioOnly)
        }
        if OkClient.isOkUrl(resolverUrl) {
            return try await inspectOk(resolverUrl, forPlayback: true, audioOnly: audioOnly)
        }
        return try await inspectRutube(resolverUrl, audioOnly: audioOnly)
    }

    /// Проверка доступных форматов для бейджа качества — без запуска воспроизведения.
    static func inspect(_ url: String) async throws -> PlaybackInfo {
        if PeerTubeClient.isApiUrl(url) {
            return try await PeerTubeClient.resolve(url, audioOnly: false)
        }
        if url.contains("dzen.ru/video/") || url.contains("zen.yandex.ru/video/") {
            return try await inspectDzen(url, forPlayback: false, audioOnly: false)
        }
        if url.contains("vkvideo.ru/") || url.contains("vk.com/video") {
            return try await inspectVk(url, audioOnly: false)
        }
        if OkClient.isOkUrl(url) {
            return try await inspectOk(url, forPlayback: false, audioOnly: false)
        }
        return try await inspectRutube(url, audioOnly: false)
    }

    /// Поисковая выдача Дзена уже содержит адреса потоков — сохраняем их, чтобы
    /// открытие ролика не требовало повторной загрузки страницы.
    static func cacheDzen(id: String, video: JSON, maxWidth: Int, maxHeight: Int) async {
        guard !id.isEmpty else { return }
        await dzenStreams.put(id, DzenStreams(video: video, maxWidth: maxWidth, maxHeight: maxHeight))
    }

    // MARK: - Дзен

    private static func inspectDzen(_ url: String, forPlayback: Bool, audioOnly: Bool) async throws -> PlaybackInfo {
        let id = try findDzenId(url)
        let cacheKey = "dzen:\(id)" + (audioOnly ? ":audio" : "")
        if let cached = await cache.get(cacheKey) { return cached }

        var streams = await dzenStreams.get(id)
        if streams == nil {
            let page = try await DzenClient.page("https://dzen.ru/video/watch/\(id)")
            guard let metadata = page.range(of: "\"videoMetaResponse\""),
                  let params = page.range(of: "var _params", options: .backwards,
                                          range: page.startIndex..<metadata.lowerBound),
                  let objectStart = page[params.lowerBound...].firstIndex(of: "{") else {
                throw HttpError.message("Дзен не отдал данные ролика")
            }
            let root = try JSON(parsing: try jsonObjectAt(page, start: objectStart))
            guard let video = root.object("ssrData")?.object("videoMetaResponse")?.object("video") else {
                throw HttpError.message("Дзен не отдал публичный поток")
            }
            let parsed = DzenStreams(video: video, maxWidth: video.int("width"), maxHeight: video.int("height"))
            await dzenStreams.put(id, parsed)
            streams = parsed
        }
        guard let streams else { throw HttpError.message("Дзен не отдал публичный поток") }

        var stream: String?
        var mime: String?
        if audioOnly, let dash = streams.dash,
           await hasDashAudio(dash, referer: nil, userAgent: DzenClient.userAgent) {
            stream = dash
            mime = "application/dash+xml"
        } else if let hls = streams.hls {
            let separateAudio = audioOnly
                ? await findHlsAudioRendition(hls, referer: nil, userAgent: DzenClient.userAgent) : nil
            stream = separateAudio ?? hls
            mime = "application/x-mpegURL"
        } else {
            stream = audioOnly ? (streams.audioFallback ?? streams.fallback) : streams.fallback
            mime = nil
        }
        guard let stream else { throw HttpError.message("Нет совместимого потока Дзен") }

        var maxWidth = streams.maxWidth
        var maxHeight = streams.maxHeight
        if !forPlayback, maxWidth == 0, let hls = streams.hls,
           let manifest = try? await get(hls, referer: nil, userAgent: DzenClient.userAgent) {
            let size = findMaxDimensions(manifest)
            maxWidth = size.0
            maxHeight = size.1
        }
        if maxWidth == 0, let fallback = streams.fallback, fallback.contains("type=5") {
            maxWidth = 1920
            maxHeight = 1080
        }
        let result = PlaybackInfo(streamUrl: stream, streamMimeType: mime,
                                  maxWidth: maxWidth, maxHeight: maxHeight)
        await cache.put(cacheKey, result)
        return result
    }

    // MARK: - OK

    private static func inspectOk(_ url: String, forPlayback: Bool, audioOnly: Bool) async throws -> PlaybackInfo {
        let id = try OkClient.findVideoId(url)
        let cacheKey = "ok:\(id)"
        if !forPlayback, let cached = await cache.get(cacheKey) { return cached }

        let player = try await OkClient.loadPlayerData(url)
        if let external = player.externalUrl {
            // OK умеет хранить чужие ролики: перенаправляем на поддерживаемый бэкенд.
            if external.contains("vkvideo.ru/") || external.contains("vk.com/video") {
                return try await inspectVk(external, audioOnly: audioOnly)
            }
            if external.contains("dzen.ru/video/") || external.contains("zen.yandex.ru/video/") {
                return try await inspectDzen(external, forPlayback: forPlayback, audioOnly: audioOnly)
            }
            if external.contains("rutube.ru/") {
                return try await inspectRutube(external, audioOnly: audioOnly)
            }
            throw HttpError.message("Видео OK размещено на неподдерживаемом внешнем сервисе")
        }
        if let mobileUrl = player.mobileUrl {
            let result = PlaybackInfo(streamUrl: mobileUrl, maxWidth: 0, maxHeight: 0)
            if !forPlayback { await cache.put(cacheKey, result) }
            return result
        }

        guard let metadata = player.metadata else {
            throw HttpError.message("OK не отдал метаданные ролика")
        }
        let movie = metadata.object("movie")
        if metadata.string("provider") == "USER_YOUTUBE" {
            throw HttpError.message("Видео OK размещено на YouTube и пока не поддерживается")
        }

        let hls = firstHttp(metadata, "hlsManifestUrl", "ondemandHls", "hlsMasterPlaylistUrl")
        var dash = firstHttp(metadata, "ondemandDash", "metadataWebmUrl")
        let metadataUrl = Url.http(metadata.string("metadataUrl"))
        if dash == nil, isDash(metadataUrl) { dash = metadataUrl }

        var bestDirect: String?
        var bestRank = Int.min
        var lowestDirect: String?
        var lowestRank = Int.max
        if let videos = metadata.array("videos") {
            for format in videos {
                guard let candidate = Url.http(format.string("url")) else { continue }
                let rank = okQualityRank(format.string("name"), candidate)
                if bestDirect == nil || rank > bestRank {
                    bestDirect = candidate
                    bestRank = rank
                }
                if lowestDirect == nil || rank < lowestRank {
                    lowestDirect = candidate
                    lowestRank = rank
                }
            }
        }

        var maxWidth = movie.map { max(0, $0.int("width")) } ?? 0
        var maxHeight = movie.map { max(0, $0.int("height")) } ?? 0
        if !forPlayback {
            var manifestDimensions = (0, 0)
            if let hls, let text = try? await OkClient.cdnText(hls) {
                manifestDimensions = findMaxDimensions(text)
            }
            if let dash, let text = try? await OkClient.cdnText(dash) {
                let dashDimensions = findMaxDimensions(text)
                if dashDimensions.0 > manifestDimensions.0 { manifestDimensions = dashDimensions }
            }
            let embeddedDash = metadata.string("metadataEmbedded")
            if !embeddedDash.isEmpty {
                let embeddedDimensions = findMaxDimensions(embeddedDash)
                if embeddedDimensions.0 > manifestDimensions.0 { manifestDimensions = embeddedDimensions }
            }
            if manifestDimensions.0 > 0 {
                maxWidth = manifestDimensions.0
                maxHeight = manifestDimensions.1
            }
        }

        var stream: String?
        var mime: String?
        if audioOnly, let dash, await hasOkDashAudio(dash) {
            stream = dash
            mime = "application/dash+xml"
        } else if let hls {
            stream = hls
            mime = "application/x-mpegURL"
        } else if let dash {
            stream = dash
            mime = "application/dash+xml"
        } else {
            stream = audioOnly ? (lowestDirect ?? bestDirect) : bestDirect
            mime = nil
        }
        guard let stream else {
            if !metadata["paymentInfo"].isMissing { throw HttpError.message("Видео OK платное") }
            throw HttpError.message("Нет совместимого потока OK")
        }
        let result = PlaybackInfo(streamUrl: stream, streamMimeType: mime,
                                  maxWidth: maxWidth, maxHeight: maxHeight)
        if !forPlayback { await cache.put(cacheKey, result) }
        return result
    }

    // MARK: - RUTUBE

    private static func inspectRutube(_ url: String, audioOnly: Bool) async throws -> PlaybackInfo {
        let id = try findRutubeId(url)
        let privateKey = Url.queryParameter(url, "p")
        let cacheKey = "rutube:\(id):\(privateKey ?? "")" + (audioOnly ? ":audio" : "")
        if let cached = await cache.get(cacheKey) { return cached }

        var optionsUrl = "https://rutube.ru/api/play/options/\(id)/?format=json&no_404=true&mq=all"
        if let privateKey, !privateKey.isEmpty { optionsUrl += "&p=\(Url.encode(privateKey))" }
        let referer = url.hasPrefix("http") ? url : "https://rutube.ru/video/\(id)/"
        let options = try JSON(parsing: try await get(optionsUrl, referer: referer))

        if let detail = options.object("detail") {
            var reason = detail.array("languages")?.first?.string("title") ?? ""
            if reason.isEmpty { reason = detail.string("type") }
            throw HttpError.message(reason.isEmpty
                ? "Видео RUTUBE недоступно"
                : "Видео RUTUBE недоступно: " + reason)
        }
        guard let balancer = options.object("video_balancer") else {
            throw HttpError.message("RUTUBE не отдал поток")
        }

        var fallback: String?
        var hls: String?
        var dash: String?
        var maxWidth = 0
        var maxHeight = 0
        for key in balancer.keys {
            let value = balancer.string(key)
            let size = findMaxDimensions(value)
            if size.0 > maxWidth {
                maxWidth = size.0
                maxHeight = size.1
            }
            if dash == nil, isDash(value) { dash = value }
            if hls == nil, isHls(value) { hls = value }
            if fallback == nil, value.hasPrefix("http") { fallback = value }
        }

        var stream: String?
        var mime: String?
        if audioOnly, let dash, await hasDashAudio(dash, referer: referer, userAgent: nil) {
            stream = dash
            mime = "application/dash+xml"
        } else if let hls {
            let separateAudio = audioOnly
                ? await findHlsAudioRendition(hls, referer: referer, userAgent: nil) : nil
            stream = separateAudio ?? hls
            mime = "application/x-mpegURL"
        } else {
            stream = fallback
            mime = nil
        }
        guard let stream else { throw HttpError.message("Нет совместимого потока RUTUBE") }
        let result = PlaybackInfo(streamUrl: stream, streamMimeType: mime,
                                  maxWidth: maxWidth, maxHeight: maxHeight)
        await cache.put(cacheKey, result)
        return result
    }

    // MARK: - VK Video

    private static func inspectVk(_ url: String, audioOnly: Bool) async throws -> PlaybackInfo {
        let id = try VkVideoId.fromUrl(url)
        let cacheKey = "vk:\(id)" + (audioOnly ? ":audio" : "")
        if let cached = await cache.get(cacheKey) { return cached }

        do {
            let result = try await inspectVkApi(id, audioOnly: audioOnly)
            await cache.put(cacheKey, result)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Публичный API периодически закрывает ролик анонимной сессии; ниже —
            // тот же путь, которым идёт веб-страница vk.com.
            let result = try await inspectVkLegacy(id, audioOnly: audioOnly)
            await cache.put(cacheKey, result)
            return result
        }
    }

    private static func inspectVkApi(_ id: String, audioOnly: Bool) async throws -> PlaybackInfo {
        let video = try await VkWebClient.videoById(id)
        guard let files = video.object("files") else {
            throw HttpError.message("VK Video не отдал публичный поток")
        }
        return try await inspectVkFiles(files, reportedWidth: video.int("width"),
                                        reportedHeight: video.int("height"), audioOnly: audioOnly)
    }

    private static func inspectVkLegacy(_ id: String, audioOnly: Bool) async throws -> PlaybackInfo {
        let body = "act=show&video=\(Url.encode(id))&al=1"
        let root = try JSON(parsing: try await postVk(body))
        guard let envelope = root.array("payload"), envelope.count >= 2 else {
            throw HttpError.message("VK Video не отдал данные ролика")
        }
        if envelope[0].stringValue == "3" { throw HttpError.message("VK Video требует авторизацию") }
        guard let payload = envelope[1].arrayValue, !payload.isEmpty,
              let options = JSON(payload[payload.count - 1]).objectValue,
              let data = options.object("player")?.array("params")?.first?.objectValue else {
            throw HttpError.message("VK Video не отдал публичный поток")
        }
        return try await inspectVkFiles(data, reportedWidth: 0, reportedHeight: 0, audioOnly: audioOnly)
    }

    private static func inspectVkFiles(_ files: JSON, reportedWidth: Int, reportedHeight: Int,
                                       audioOnly: Bool) async throws -> PlaybackInfo {
        var hls = Url.http(files.string("hls"))
            ?? Url.http(files.string("hls_fmp4"))
            ?? Url.http(files.string("hls_streams"))
        var dash = Url.http(files.string("dash_sep"))
            ?? Url.http(files.string("dash"))
            ?? Url.http(files.string("dash_streams"))
        var fallback: String?
        var bestHeight = 0
        var lowestFallback: String?
        var lowestHeight = Int.max
        for key in files.keys {
            guard let value = Url.http(files.string(key)) else { continue }
            if hls == nil, key.hasPrefix("hls"), !key.contains("live_playback") { hls = value }
            if dash == nil, key.hasPrefix("dash"), !key.contains("live_playback"), key != "dash_uni" {
                dash = value
            }
            let height = qualityHeight(key)
            if height > bestHeight {
                bestHeight = height
                fallback = value
            }
            if height > 0 && height < lowestHeight {
                lowestHeight = height
                lowestFallback = value
            }
        }

        var stream: String?
        var mime: String?
        if audioOnly, let dash, await hasDashAudio(dash, referer: "https://vkvideo.ru/", userAgent: nil) {
            stream = dash
            mime = "application/dash+xml"
        } else if let hls {
            let separateAudio = audioOnly
                ? await findHlsAudioRendition(hls, referer: "https://vkvideo.ru/", userAgent: nil) : nil
            stream = separateAudio ?? hls
            mime = "application/x-mpegURL"
        } else {
            stream = audioOnly ? (lowestFallback ?? fallback) : fallback
            mime = nil
        }
        guard let stream else { throw HttpError.message("Нет совместимого потока VK Video") }
        if bestHeight <= 0 { bestHeight = max(0, reportedHeight) }
        let bestWidth: Int
        if bestHeight <= 0 { bestWidth = max(0, reportedWidth) }
        else if reportedWidth > 0 && reportedHeight == bestHeight { bestWidth = reportedWidth }
        else { bestWidth = Int((Double(bestHeight) * 16.0 / 9.0).rounded()) }
        return PlaybackInfo(streamUrl: stream, streamMimeType: mime,
                            maxWidth: bestWidth, maxHeight: bestHeight)
    }

    // MARK: - Разбор манифестов

    private static func isHls(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.contains(".m3u8") || value.contains("ct=8")
    }

    private static func isDash(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.contains(".mpd") || value.contains("ct=6")
    }

    private static func firstHttp(_ object: JSON, _ keys: String...) -> String? {
        for key in keys {
            if let value = Url.http(object.string(key)) { return value }
        }
        return nil
    }

    private static func hasOkDashAudio(_ dashUrl: String) async -> Bool {
        guard let manifest = try? await OkClient.cdnText(dashUrl) else { return false }
        return manifestHasAudio(manifest)
    }

    private static func hasDashAudio(_ dashUrl: String, referer: String?, userAgent: String?) async -> Bool {
        guard let manifest = try? await get(dashUrl, referer: referer, userAgent: userAgent) else { return false }
        return manifestHasAudio(manifest)
    }

    private static func manifestHasAudio(_ manifest: String) -> Bool {
        manifest.contains("contentType=\"audio\"")
            || manifest.contains("mimeType=\"audio/")
            || manifest.contains("<AudioChannelConfiguration")
    }

    private static func okQualityRank(_ name: String, _ url: String) -> Int {
        switch name.lowercased() {
        case "mobile": return 0
        case "lowest": return 1
        case "low": return 2
        case "sd": return 3
        case "hd": return 4
        case "full": return 5
        case "quad": return 6
        case "ultra": return 7
        default: break
        }
        let types = ["4", "0", "1", "2", "3", "5", "6", "7"]
        for (index, type) in types.enumerated()
        where url.contains("type=\(type)") || url.contains("type/\(type)") {
            return index
        }
        return -1
    }

    private static func findHlsAudioRendition(_ hlsUrl: String, referer: String?,
                                              userAgent: String?) async -> String? {
        guard let manifest = try? await get(hlsUrl, referer: referer, userAgent: userAgent) else { return nil }
        var first: String?
        for raw in manifest.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            guard line.hasPrefix("#EXT-X-MEDIA:"), line.contains("TYPE=AUDIO"),
                  let uri = attribute(line, "URI"),
                  let resolved = Url.resolve(uri, base: hlsUrl) else { continue }
            if line.contains("DEFAULT=YES") { return resolved }
            if first == nil { first = resolved }
        }
        return first
    }

    private static func attribute(_ line: String, _ name: String) -> String? {
        let marker = name + "=\""
        guard let start = line.range(of: marker)?.upperBound,
              let end = line[start...].firstIndex(of: "\"") else { return nil }
        return end > start ? String(line[start..<end]) : nil
    }

    /// Вырезает сбалансированный JSON-объект, начиная с указанной скобки: страница
    /// Дзена встраивает данные в `var _params = {...}` без каких-либо разделителей.
    private static func jsonObjectAt(_ value: String, start: String.Index) throws -> String {
        var depth = 0
        var string = false
        var escaped = false
        var index = start
        while index < value.endIndex {
            let current = value[index]
            if string {
                if escaped { escaped = false }
                else if current == "\\" { escaped = true }
                else if current == "\"" { string = false }
            } else if current == "\"" {
                string = true
            } else if current == "{" {
                depth += 1
            } else if current == "}" {
                depth -= 1
                if depth == 0 { return String(value[start...index]) }
            }
            index = value.index(after: index)
        }
        throw HttpError.message("Повреждены данные ролика Дзен")
    }

    private static func findDzenId(_ url: String) throws -> String {
        guard let range = url.range(of: "/video/watch/") else {
            throw HttpError.message("Не найден ID Дзен")
        }
        let id = String(url[range.upperBound...].prefix { DzenClient.isIdChar($0) })
        if id.isEmpty { throw HttpError.message("Не найден ID Дзен") }
        return id
    }

    private static func qualityHeight(_ key: String) -> Int {
        let start: Int
        if key.hasPrefix("url") { start = 3 }
        else if key.hasPrefix("cache") { start = 5 }
        else { return 0 }
        let digits = String(key.dropFirst(start).prefix { $0.isNumber })
        return Int(digits) ?? 0
    }

    /// Ищет самое большое `ШИРИНАxВЫСОТА` в произвольном тексте — так качество
    /// извлекается и из манифестов, и из подписанных ссылок балансировщика.
    private static func findMaxDimensions(_ value: String) -> (Int, Int) {
        let characters = Array(value)
        var bestWidth = 0
        var bestHeight = 0
        var index = 1
        while index < characters.count - 1 {
            defer { index += 1 }
            guard characters[index] == "x" else { continue }
            var left = index - 1
            while left >= 0 && characters[left].isNumber { left -= 1 }
            var right = index + 1
            while right < characters.count && characters[right].isNumber { right += 1 }
            if left == index - 1 || right == index + 1 { continue }
            guard let width = Int(String(characters[(left + 1)..<index])),
                  let height = Int(String(characters[(index + 1)..<right])) else { continue }
            if width > bestWidth && width <= 7680 && height <= 4320 {
                bestWidth = width
                bestHeight = height
            }
        }
        return (bestWidth, bestHeight)
    }

    /// Идентификатор RUTUBE — первая же последовательность из 32 букв и цифр.
    private static func findRutubeId(_ url: String) throws -> String {
        var candidate = ""
        for character in url {
            let alphaNumeric = (character >= "0" && character <= "9")
                || (character >= "a" && character <= "z")
                || (character >= "A" && character <= "Z")
            if alphaNumeric {
                candidate.append(character)
                if candidate.count == 32 { return candidate }
            } else {
                candidate = ""
            }
        }
        throw HttpError.message("Не найден ID RUTUBE")
    }

    private struct DzenStreams {
        let hls: String?
        let dash: String?
        let fallback: String?
        let audioFallback: String?
        let maxWidth: Int
        let maxHeight: Int
        let loadedAt = Date()

        init(video: JSON, maxWidth: Int, maxHeight: Int) {
            var hls: String?
            var dash: String?
            var fallback: String?
            var audioFallback: String?
            let direct = Url.http(video.string("id"))
            if isDash(direct) { dash = direct }
            else if isHls(direct) { hls = direct }
            else if let direct {
                fallback = direct
                audioFallback = direct
            }
            if let streams = video.array("streams") {
                for stream in streams {
                    guard let candidate = Url.http(stream.stringValue) else { continue }
                    if dash == nil, isDash(candidate) { dash = candidate }
                    if hls == nil, isHls(candidate) { hls = candidate }
                    if fallback == nil, candidate.contains("ct=0") { fallback = candidate }
                    if candidate.contains("ct=0"), audioFallback == nil || candidate.contains("type=4") {
                        audioFallback = candidate
                    }
                }
            }
            if let oneVideo = video.array("oneVideoStreams") {
                for item in oneVideo {
                    guard let candidate = Url.http(item.string("url")) else { continue }
                    let type = item.string("type")
                    if dash == nil, type == "dash" || isDash(candidate) { dash = candidate }
                    if hls == nil, type == "hls" || isHls(candidate) { hls = candidate }
                    if fallback == nil, type == "fullhd" { fallback = candidate }
                    if candidate.contains("ct=0"), audioFallback == nil || candidate.contains("type=4") {
                        audioFallback = candidate
                    }
                }
            }
            self.hls = hls
            self.dash = dash
            self.fallback = fallback
            self.audioFallback = audioFallback
            self.maxWidth = maxWidth
            self.maxHeight = maxHeight
        }
    }

    // MARK: - Сеть

    private static func get(_ address: String, referer: String?, userAgent: String? = nil) async throws -> String {
        var options = Http.Options()
        options.accept = "application/json,text/html,*/*"
        options.userAgent = userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15) AppleWebKit/537.36"
        options.referer = referer
        options.timeout = 8
        return try await Http.text(address, options)
    }

    private static func postVk(_ body: String) async throws -> String {
        var options = Http.Options()
        options.method = "POST"
        options.body = Data(body.utf8)
        options.contentType = "application/x-www-form-urlencoded; charset=UTF-8"
        options.accept = "application/json,*/*"
        options.referer = "https://vk.com/al_video.php"
        options.extraHeaders["X-Requested-With"] = "XMLHttpRequest"
        options.userAgent = VkWebClient.userAgent
        options.timeout = 10
        options.errorPrefix = "VK Video"
        return try await Http.text("https://vk.com/al_video.php", options)
    }
}
