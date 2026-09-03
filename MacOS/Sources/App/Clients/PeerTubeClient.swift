import Foundation

/// Низкоприоритетный поиск и воспроизведение публичных роликов федерации PeerTube.
/// Глобальный индекс Sepia Search отдаёт много шума, поэтому кандидаты жёстко
/// фильтруются по полному названию и длительности полного метра, а затем
/// проверяются на исходном сервере — карточка показывается только после этого.
enum PeerTubeClient {
    static let source = VideoSource.peerTube
    private static let searchEndpoint = "https://sepiasearch.org/api/v1/search/videos"
    private static let userAgent = "0W-Tube/0.7.3 PeerTube"
    private static let minDurationSeconds = 40 * 60
    private static let searchLimit = 20
    private static let resultLimit = 3
    private static let inspectionLimit = 3
    private static let maxJsonBytes = 1024 * 1024
    private static let maxManifestBytes = 64 * 1024
    private static let maxCacheEntries = 32
    private static let cacheInterval: TimeInterval = 10 * 60

    private static let stopWords: Set<String> = [
        "а", "без", "в", "во", "для", "до", "за", "и", "из", "или", "к", "ко",
        "на", "не", "о", "об", "от", "по", "под", "при", "про", "с", "со", "у",
        "a", "an", "and", "for", "from", "in", "of", "on", "or", "the", "to"]
    private static let queryDecorations: Set<String> = [
        "фильм", "кино", "смотреть", "онлайн", "film", "movie", "online"]
    private static let unwanted: Set<String> = [
        "тизер", "трейлер", "обзор", "фрагмент", "отрывок", "реакция", "short",
        "shorts", "teaser", "trailer", "review", "reaction", "clip"]
    private static let videoCodecs = ["av01", "avc1", "avc3", "hev1", "hvc1", "theora", "vp8", "vp9", "vp09"]
    private static let audioCodecs = ["ac-3", "alac", "ec-3", "flac", "mp4a", "opus", "vorbis"]

    // MARK: - Поиск

    static func search(query: String, minWidth: Int, thumbnailWidth: Int) async throws -> [VideoItem] {
        let normalized = queryForTitle(query)
        if normalized.isEmpty { return [] }

        var candidates: [String: Candidate] = [:]
        var order: [String] = []
        addCandidates(try await searchOnce(normalized), into: &candidates, order: &order)
        var result = await inspectAccepted(query: query, candidates: order.compactMap { candidates[$0] },
                                           minWidth: minWidth, thumbnailWidth: thumbnailWidth)

        let latin = TitleText.transliterate(normalized)
        if result.isEmpty && !latin.isEmpty && latin != normalized {
            try Task.checkCancellation()
            addCandidates(try await searchOnce(latin), into: &candidates, order: &order)
            result = await inspectAccepted(query: query, candidates: order.compactMap { candidates[$0] },
                                           minWidth: minWidth, thumbnailWidth: thumbnailWidth)
        }
        return result
    }

    static func isApiUrl(_ value: String?) -> Bool {
        guard let value, value.contains("/api/v1/videos/"),
              let components = URLComponents(string: value) else { return false }
        return components.scheme?.lowercased() == "https" && components.host != nil
    }

    static func resolve(_ apiUrl: String, audioOnly: Bool) async throws -> PlaybackInfo {
        let media = try await loadMedia(apiUrl)
        if audioOnly {
            guard let audioUrl = media.audioUrl else {
                throw HttpError.message("PeerTube не отдал отдельный или низкокачественный аудиопоток")
            }
            return PlaybackInfo(streamUrl: audioUrl, streamMimeType: media.audioMimeType,
                                maxWidth: media.maxWidth, maxHeight: media.maxHeight)
        }
        guard let streamUrl = media.streamUrl else {
            throw HttpError.message("PeerTube не отдал воспроизводимый поток")
        }
        return PlaybackInfo(streamUrl: streamUrl, streamMimeType: media.streamMimeType,
                            maxWidth: media.maxWidth, maxHeight: media.maxHeight)
    }

    private static func inspectAccepted(query: String, candidates: [Candidate],
                                        minWidth: Int, thumbnailWidth: Int) async -> [VideoItem] {
        var accepted: [(candidate: Candidate, score: Int)] = []
        for candidate in candidates {
            let evaluation = evaluate(query: query, title: candidate.title,
                                      durationSeconds: candidate.durationSeconds)
            if evaluation.accepted { accepted.append((candidate, evaluation.score)) }
        }
        accepted.sort { $0.score > $1.score }

        var result: [VideoItem] = []
        var inspected = 0
        for ranked in accepted {
            if Task.isCancelled || inspected >= inspectionLimit { break }
            inspected += 1
            let candidate = ranked.candidate
            do {
                let media = try await loadMedia(candidate.apiUrl)
                guard media.streamUrl != nil, media.maxWidth >= minWidth else { continue }
                let thumbnail = media.thumbnail(for: thumbnailWidth) ?? candidate.thumbnail
                let duration = media.durationSeconds > 0
                    ? media.durationSeconds * 1000 : candidate.durationSeconds * 1000
                result.append(VideoItem(source: source, title: candidate.title,
                                        thumbnail: thumbnail,
                                        playUrl: candidate.apiUrl, pageUrl: candidate.pageUrl,
                                        durationMs: duration,
                                        maxWidth: media.maxWidth, maxHeight: media.maxHeight))
                if result.count >= resultLimit { break }
            } catch {
                // В федеративных индексах регулярно встречаются остановленные
                // или недоступные исходные серверы.
            }
        }
        return result
    }

    private static func searchOnce(_ query: String) async throws -> [JSON] {
        let address = searchEndpoint
            + "?search=\(Url.encode(query))&count=\(searchLimit)"
            + "&start=0&nsfw=false&isLive=false&durationMin=\(minDurationSeconds)"
        return try await getJson(address, limit: maxJsonBytes).array("data") ?? []
    }

    private static func addCandidates(_ values: [JSON], into target: inout [String: Candidate],
                                      order: inout [String]) {
        for item in values {
            guard let candidate = Candidate(item) else { continue }
            if target[candidate.pageUrl] == nil {
                target[candidate.pageUrl] = candidate
                order.append(candidate.pageUrl)
            }
        }
    }

    // MARK: - Фильтрация кандидатов

    struct Evaluation {
        let accepted: Bool
        let score: Int

        static func accept(_ score: Int) -> Evaluation { Evaluation(accepted: true, score: score) }
        static func reject(_ score: Int = -10_000) -> Evaluation { Evaluation(accepted: false, score: score) }
    }

    static func evaluate(query: String, title: String, durationSeconds: Int) -> Evaluation {
        if durationSeconds < minDurationSeconds { return .reject() }
        let normalizedQuery = queryForTitle(query)
        let nativeTitleWords = TitleText.words(TitleText.normalize(title))
        let nativeQueryWords = TitleText.words(normalizedQuery)
        for word in nativeTitleWords where unwanted.contains(word) && !nativeQueryWords.contains(word) {
            return .reject()
        }
        let nativeView = evaluateView(query: normalizedQuery, title: TitleText.normalize(title))
        let latinView = evaluateView(query: TitleText.transliterate(normalizedQuery),
                                     title: TitleText.transliterate(TitleText.normalize(title)))
        return latinView.accepted || latinView.score > nativeView.score ? latinView : nativeView
    }

    private static func evaluateView(query: String, title: String) -> Evaluation {
        let queryPhrase = TitleText.words(query)
        let titlePhrase = TitleText.words(title)
        let queryWords = significantWords(queryPhrase)
        let titleWords = significantWords(titlePhrase)
        if queryWords.isEmpty || titleWords.isEmpty { return .reject() }

        for word in titleWords where unwanted.contains(word) && !queryWords.contains(word) {
            return .reject()
        }

        let ordered = orderedMatches(queryWords, titleWords)
        let contiguousStart = contiguousMatchStart(queryPhrase, titlePhrase)
        let contiguous = contiguousStart >= 0
        let exact = contiguous && queryPhrase.count == titlePhrase.count
        var score = ordered * 5000 / max(1, queryWords.count)
        if contiguous { score += 8000 }
        if exact { score += 8000 }
        score += min(240, titlePhrase.count)

        if queryWords.count == 1 {
            let yearSuffix = contiguousStart == 0 && titlePhrase.count == queryPhrase.count + 1
                && TitleText.isYear(titlePhrase[titlePhrase.count - 1])
            return exact || yearSuffix ? .accept(score) : .reject(score)
        }
        return contiguous && contiguousStart <= 1 ? .accept(score) : .reject(score)
    }

    private static func orderedMatches(_ query: [String], _ title: [String]) -> Int {
        var matched = 0
        var start = 0
        for queryWord in query {
            var index = start
            while index < title.count {
                if TitleText.tokenMatches(queryWord, title[index]) {
                    matched += 1
                    start = index + 1
                    break
                }
                index += 1
            }
        }
        return matched
    }

    private static func contiguousMatchStart(_ query: [String], _ title: [String]) -> Int {
        if query.isEmpty || query.count > title.count { return -1 }
        for start in 0...(title.count - query.count) {
            var matches = true
            for offset in 0..<query.count where !TitleText.tokenMatches(query[offset], title[start + offset]) {
                matches = false
                break
            }
            if matches { return start }
        }
        return -1
    }

    // MARK: - Метаданные и потоки

    private actor MediaCache {
        private var values: [String: Media] = [:]

        func get(_ key: String) -> Media? {
            guard let value = values[key],
                  Date().timeIntervalSince(value.loadedAt) < cacheInterval else { return nil }
            return value
        }

        func put(_ key: String, _ value: Media) {
            let now = Date()
            for (entry, media) in values where now.timeIntervalSince(media.loadedAt) >= cacheInterval {
                values.removeValue(forKey: entry)
            }
            if values.count >= maxCacheEntries,
               let oldest = values.min(by: { $0.value.loadedAt < $1.value.loadedAt })?.key {
                values.removeValue(forKey: oldest)
            }
            values[key] = value
        }
    }

    private static let cache = MediaCache()

    private static func loadMedia(_ apiUrl: String) async throws -> Media {
        guard isApiUrl(apiUrl) else { throw HttpError.message("Неверный адрес PeerTube") }
        if let cached = await cache.get(apiUrl) { return cached }

        let metadata = try await getJson(apiUrl, limit: maxJsonBytes)
        let base = try Url.httpsOrigin(apiUrl)
        let thumbnails = parseThumbnails(metadata, base: base)

        var direct = parseFiles(metadata.array("files"), base: base)
        var maxWidth = direct.maxWidth
        var maxHeight = direct.maxHeight

        var masterUrl: String?
        var bestHls: HlsInfo?
        var playlistSaysMuxed = false
        if let playlists = metadata.array("streamingPlaylists") {
            for playlist in playlists {
                let files = parseFiles(playlist.array("files"), base: base)
                if files.maxWidth > maxWidth {
                    maxWidth = files.maxWidth
                    maxHeight = files.maxHeight
                }
                if files.bestMuxedUrl != nil {
                    playlistSaysMuxed = true
                    if direct.bestMuxedUrl == nil || files.bestMuxedHeight > direct.bestMuxedHeight {
                        direct.bestMuxedUrl = files.bestMuxedUrl
                        direct.bestMuxedHeight = files.bestMuxedHeight
                    }
                    if direct.lowestMuxedUrl == nil || files.lowestMuxedHeight < direct.lowestMuxedHeight {
                        direct.lowestMuxedUrl = files.lowestMuxedUrl
                        direct.lowestMuxedHeight = files.lowestMuxedHeight
                    }
                }
                if let audioUrl = files.audioUrl, files.audioSize < direct.audioSize {
                    direct.audioUrl = audioUrl
                    direct.audioSize = files.audioSize
                }
                guard let candidateMaster = Url.resolve(playlist.string("playlistUrl"), base: base),
                      candidateMaster.hasPrefix("https") else { continue }
                do {
                    let manifest = try await getText(candidateMaster, limit: maxManifestBytes)
                    let info = parseHls(playlistUrl: candidateMaster, manifest: manifest)
                    guard info.valid else { continue }
                    if masterUrl == nil || info.maxWidth > (bestHls?.maxWidth ?? 0) {
                        masterUrl = candidateMaster
                        bestHls = info
                    }
                } catch {
                    continue
                }
            }
        }

        if let bestHls, bestHls.maxWidth > maxWidth {
            maxWidth = bestHls.maxWidth
            maxHeight = bestHls.maxHeight
        }
        let hlsPlayable = bestHls != nil
            && (bestHls!.muxed || bestHls!.separateAudioUrl != nil || playlistSaysMuxed)
        let streamUrl = hlsPlayable ? masterUrl : direct.bestMuxedUrl
        let streamMime = hlsPlayable ? "application/x-mpegURL" : nil

        // Режим экономии трафика: сначала отдельная аудиодорожка, затем аудиорендишен
        // HLS и лишь в последнюю очередь самый низкий видеопоток.
        var audioUrl = direct.audioUrl
        var audioMime: String? = direct.audioUrl == nil ? nil : "audio/mp4"
        if audioUrl == nil, let separate = bestHls?.separateAudioUrl {
            audioUrl = separate
            audioMime = "application/x-mpegURL"
        }
        if audioUrl == nil, let lowest = bestHls?.lowestMuxedUrl {
            audioUrl = lowest
            audioMime = "application/x-mpegURL"
        }
        if audioUrl == nil, let lowest = direct.lowestMuxedUrl {
            audioUrl = lowest
            audioMime = nil
        }

        let result = Media(streamUrl: streamUrl, streamMimeType: streamMime,
                           audioUrl: audioUrl, audioMimeType: audioMime,
                           maxWidth: maxWidth, maxHeight: maxHeight,
                           durationSeconds: metadata.long("duration"), thumbnails: thumbnails)
        await cache.put(apiUrl, result)
        return result
    }

    private static func parseFiles(_ files: [JSON]?, base: String) -> FileSelection {
        var result = FileSelection()
        guard let files else { return result }
        for file in files {
            guard let url = Url.resolve(file.string("fileUrl"), base: base),
                  url.hasPrefix("https") else { continue }
            let resolution = file.object("resolution")
            var width = max(0, file.int("width"))
            var height = max(0, file.int("height"))
            if height == 0, let resolution { height = max(0, resolution.int("id")) }
            if width == 0 && height > 0 { width = Int((Double(height) * 16.0 / 9.0).rounded()) }
            if width > result.maxWidth {
                result.maxWidth = width
                result.maxHeight = height
            }
            let audioLabel = height == 0
                || (resolution?.string("label").lowercased().contains("audio") ?? false)
            let hasVideo = file.has("hasVideo") ? file.bool("hasVideo") : !audioLabel
            let hasAudio = file.has("hasAudio") ? file.bool("hasAudio") : audioLabel
            let size = file.long("size", Int.max)
            if !hasVideo && hasAudio && size < result.audioSize {
                result.audioUrl = url
                result.audioSize = size
            } else if hasVideo && hasAudio {
                if height > result.bestMuxedHeight {
                    result.bestMuxedUrl = url
                    result.bestMuxedHeight = height
                }
                if height < result.lowestMuxedHeight {
                    result.lowestMuxedUrl = url
                    result.lowestMuxedHeight = height
                }
            }
        }
        return result
    }

    static func parseHls(playlistUrl: String, manifest: String?) -> HlsInfo {
        var result = HlsInfo()
        result.valid = manifest?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") ?? false
        guard result.valid, let manifest else { return result }
        var audioGroups: [String: String] = [:]
        var pending: String?
        for raw in manifest.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let type = hlsAttribute(line, "TYPE")
                let uri = hlsAttribute(line, "URI")
                let group = hlsAttribute(line, "GROUP-ID")
                if type?.uppercased() == "AUDIO", let uri,
                   let resolved = Url.resolve(uri, base: playlistUrl), resolved.hasPrefix("https") {
                    audioGroups[group ?? ""] = resolved
                    if result.separateAudioUrl == nil
                        || hlsAttribute(line, "DEFAULT")?.uppercased() == "YES" {
                        result.separateAudioUrl = resolved
                    }
                }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = line
            } else if let info = pending, !line.isEmpty, !line.hasPrefix("#") {
                let variant = Url.resolve(line, base: playlistUrl).flatMap { $0.hasPrefix("https") ? $0 : nil }
                let size = dimensions(hlsAttribute(info, "RESOLUTION"))
                if size.0 > result.maxWidth {
                    result.maxWidth = size.0
                    result.maxHeight = size.1
                }
                let codecs = hlsAttribute(info, "CODECS")
                let video = size.0 > 0 || containsPrefix(codecs, videoCodecs)
                let audio = containsPrefix(codecs, audioCodecs)
                let audioGroup = hlsAttribute(info, "AUDIO")
                if video && audio {
                    result.muxed = true
                    if let variant, result.lowestMuxedUrl == nil || size.1 < result.lowestMuxedHeight {
                        result.lowestMuxedUrl = variant
                        result.lowestMuxedHeight = size.1
                    }
                }
                if video, let audioGroup, let resolved = audioGroups[audioGroup] {
                    result.separateAudioUrl = resolved
                }
                pending = nil
            }
        }
        return result
    }

    private static func parseThumbnails(_ metadata: JSON, base: String) -> [Thumbnail] {
        var order: [String] = []
        var values: [String: Thumbnail] = [:]
        func add(_ thumbnail: Thumbnail) {
            if values[thumbnail.url] == nil { order.append(thumbnail.url) }
            values[thumbnail.url] = thumbnail
        }
        if let items = metadata.array("thumbnails") {
            for item in items {
                guard let url = Url.resolve(item.string("fileUrl"), base: base),
                      url.hasPrefix("https") else { continue }
                add(Thumbnail(url: url, width: max(0, item.int("width")),
                              height: max(0, item.int("height"))))
            }
        }
        for path in [metadata.string("thumbnailPath"), metadata.string("previewPath")] {
            guard let url = Url.resolve(path, base: base), url.hasPrefix("https"),
                  values[url] == nil else { continue }
            add(Thumbnail(url: url, width: 0, height: 0))
        }
        return order.compactMap { values[$0] }
    }

    // MARK: - Вспомогательное

    private static func queryForTitle(_ value: String) -> String {
        var values = TitleText.words(TitleText.normalize(value))
        while let last = values.last, queryDecorations.contains(last) || TitleText.isYear(last) {
            values.removeLast()
        }
        return values.joined(separator: " ")
    }

    private static func significantWords(_ values: [String]) -> [String] {
        let result = values.filter { !stopWords.contains($0) && $0.count >= 2 }
        return result.isEmpty ? values : result
    }

    private static func dimensions(_ value: String?) -> (Int, Int) {
        guard let value, let marker = value.firstIndex(of: "x"), marker != value.startIndex,
              marker != value.index(before: value.endIndex),
              let width = Int(value[value.startIndex..<marker]),
              let height = Int(value[value.index(after: marker)...]) else { return (0, 0) }
        return (width, height)
    }

    private static func containsPrefix(_ codecs: String?, _ prefixes: [String]) -> Bool {
        guard let codecs else { return false }
        for codec in codecs.split(separator: ",") {
            let value = codec.trimmingCharacters(in: .whitespaces).lowercased()
            if prefixes.contains(where: value.hasPrefix) { return true }
        }
        return false
    }

    private static func hlsAttribute(_ line: String, _ name: String) -> String? {
        let marker = name + "="
        var search = line.startIndex..<line.endIndex
        var found: String.Index?
        while let range = line.range(of: marker, range: search) {
            // Имя атрибута должно начинаться сразу после `:` или `,`, иначе это хвост
            // другого атрибута (`AUDIO=` внутри `GROUP-ID="..."` и подобное).
            if range.lowerBound == line.startIndex {
                found = range.upperBound
                break
            }
            let before = line[line.index(before: range.lowerBound)]
            if before == ":" || before == "," {
                found = range.upperBound
                break
            }
            search = range.upperBound..<line.endIndex
        }
        guard let start = found else { return nil }
        if start < line.endIndex, line[start] == "\"" {
            let contentStart = line.index(after: start)
            guard let end = line[contentStart...].firstIndex(of: "\"") else { return nil }
            return String(line[contentStart..<end])
        }
        let end = line[start...].firstIndex(of: ",") ?? line.endIndex
        return String(line[start..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func baseOptions(limit: Int) -> Http.Options {
        var options = Http.Options()
        options.accept = "application/json,application/vnd.apple.mpegurl,*/*"
        options.userAgent = userAgent
        options.timeout = 8
        options.limit = limit
        options.errorPrefix = "PeerTube"
        return options
    }

    private static func getJson(_ address: String, limit: Int) async throws -> JSON {
        try await Http.json(address, baseOptions(limit: limit))
    }

    private static func getText(_ address: String, limit: Int) async throws -> String {
        try await Http.text(address, baseOptions(limit: limit))
    }

    // MARK: - Модели

    private struct Candidate {
        let title: String
        let pageUrl: String
        let apiUrl: String
        let thumbnail: String
        let durationSeconds: Int

        init?(_ item: JSON) {
            guard let page = Url.resolve(item.string("url"), base: nil), page.hasPrefix("https") else { return nil }
            let uuid = item.string("uuid")
            if uuid.isEmpty { return nil }
            guard let origin = try? Url.httpsOrigin(page) else { return nil }
            let name = item.string("name")
            self.title = name.isEmpty ? "Видео PeerTube" : name
            self.pageUrl = page
            self.apiUrl = origin + "api/v1/videos/" + Url.encode(uuid)
            self.thumbnail = Url.resolve(item.string("thumbnailUrl"), base: page) ?? ""
            self.durationSeconds = max(0, item.int("duration"))
        }
    }

    struct HlsInfo {
        var valid = false
        var muxed = false
        var maxWidth = 0
        var maxHeight = 0
        var separateAudioUrl: String?
        var lowestMuxedUrl: String?
        var lowestMuxedHeight = Int.max
    }

    private struct FileSelection {
        var bestMuxedUrl: String?
        var bestMuxedHeight = -1
        var lowestMuxedUrl: String?
        var lowestMuxedHeight = Int.max
        var audioUrl: String?
        var audioSize = Int.max
        var maxWidth = 0
        var maxHeight = 0
    }

    private struct Thumbnail {
        let url: String
        let width: Int
        let height: Int
    }

    private struct Media {
        let streamUrl: String?
        let streamMimeType: String?
        let audioUrl: String?
        let audioMimeType: String?
        let maxWidth: Int
        let maxHeight: Int
        let durationSeconds: Int
        let thumbnails: [Thumbnail]
        let loadedAt = Date()

        /// Наименьшая обложка, покрывающая ширину карточки; вертикальные превью
        /// (соотношение уже 12:10) отбрасываются.
        func thumbnail(for targetWidth: Int) -> String? {
            var best: Thumbnail?
            var largest: Thumbnail?
            for candidate in thumbnails {
                guard candidate.width > 0, candidate.height > 0,
                      candidate.width * 10 >= candidate.height * 12 else { continue }
                if largest == nil || candidate.width > largest!.width { largest = candidate }
                if candidate.width >= targetWidth && (best == nil || candidate.width < best!.width) {
                    best = candidate
                }
            }
            if let best { return best.url }
            if let largest { return largest.url }
            return thumbnails.first?.url
        }
    }
}
