import Foundation

enum VideoSource {
    static let rutube = "RUTUBE"
    static let vk = "VK VIDEO"
    static let dzen = "ДЗЕН"
    static let ok = "OK"
    static let peerTube = "PEERTUBE"

    /// Подпись источника в статусной строке (в Java это отдельные строки в `finishSource`).
    static func label(_ source: String) -> String {
        switch source {
        case vk: return "VK Video"
        case dzen: return "Дзен"
        case peerTube: return "PeerTube"
        default: return source
        }
    }
}

/// Неизменяемая карточка результата. `playUrl` — не ссылка на поток, а адрес для
/// резолвера (`StreamResolver` определяет бэкенд по его виду); настоящий поток
/// добывается непосредственно перед воспроизведением, потому что подписанные
/// CDN-ссылки живут недолго.
struct VideoItem: Identifiable, Hashable {
    let source: String
    let title: String
    let subtitle: String
    let thumbnail: String
    let playUrl: String
    let pageUrl: String
    let durationMs: Int
    let maxWidth: Int
    let maxHeight: Int

    init(source: String, title: String, subtitle: String = "", thumbnail: String,
         playUrl: String, pageUrl: String, durationMs: Int = 0,
         maxWidth: Int = 0, maxHeight: Int = 0) {
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.thumbnail = thumbnail
        self.playUrl = playUrl
        self.pageUrl = pageUrl
        self.durationMs = max(0, durationMs)
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    func withQuality(_ width: Int, _ height: Int) -> VideoItem {
        VideoItem(source: source, title: title, subtitle: subtitle, thumbnail: thumbnail,
                  playUrl: playUrl, pageUrl: pageUrl, durationMs: durationMs,
                  maxWidth: width, maxHeight: height)
    }

    func withDuration(_ duration: Int) -> VideoItem {
        VideoItem(source: source, title: title, subtitle: subtitle, thumbnail: thumbnail,
                  playUrl: playUrl, pageUrl: pageUrl, durationMs: duration,
                  maxWidth: maxWidth, maxHeight: maxHeight)
    }

    var stableKey: String {
        pageUrl.isEmpty ? "\(source)\n\(playUrl)" : "\(source)\n\(pageUrl)"
    }

    var id: String { stableKey }

    var thumbnailUrl: URL? { thumbnail.isEmpty ? nil : URL(string: thumbnail) }

    var qualityLabel: String {
        if maxWidth >= 3840 { return "4K" }
        if maxWidth >= 2560 { return "1440p" }
        if maxWidth >= 1920 { return "1080p" }
        if maxWidth >= 1280 { return "720p" }
        return maxWidth > 0 ? "\(maxWidth)px" : ""
    }

    var durationLabel: String {
        guard durationMs > 0 else { return "" }
        let total = durationMs / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    static func == (left: VideoItem, right: VideoItem) -> Bool { left.stableKey == right.stableKey }
    func hash(into hasher: inout Hasher) { hasher.combine(stableKey) }
}

struct PlaybackInfo {
    let streamUrl: String
    let streamMimeType: String?
    let maxWidth: Int
    let maxHeight: Int
    let loadedAt: Date

    init(streamUrl: String, streamMimeType: String? = nil, maxWidth: Int, maxHeight: Int) {
        self.streamUrl = streamUrl
        self.streamMimeType = streamMimeType
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.loadedAt = Date()
    }
}
