import Foundation
import CryptoKit

/// Локальное состояние приложения. На Android это три разных файла
/// `SharedPreferences`; здесь — один `UserDefaults` с теми же тремя пространствами
/// имён в префиксах ключей. Наружу не уходит ничего: ни аккаунтов, ни токенов.
private enum Defaults {
    static let store = UserDefaults.standard

    static func string(_ key: String, _ fallback: String = "") -> String {
        store.string(forKey: key) ?? fallback
    }

    static func int(_ key: String, _ fallback: Int = 0) -> Int {
        store.object(forKey: key) == nil ? fallback : store.integer(forKey: key)
    }

    static func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        store.object(forKey: key) == nil ? fallback : store.bool(forKey: key)
    }

    static func double(_ key: String, _ fallback: Double = 0) -> Double {
        store.object(forKey: key) == nil ? fallback : store.double(forKey: key)
    }
}

/// Последний поиск, фильтр и открытый ролик — чтобы приложение возвращалось туда,
/// где его закрыли.
enum StateStore {
    private static let prefix = "playback_state."

    enum Screen: String {
        case search
        case history
        case player
    }

    static func saveSearch(query: String, filter: Int, trafficMode: Bool) {
        Defaults.store.set(query, forKey: prefix + "query")
        Defaults.store.set(filter, forKey: prefix + "filter")
        Defaults.store.set(trafficMode, forKey: prefix + "traffic_mode")
    }

    static func savePlayer(item: VideoItem, position: Int, trafficMode: Bool = false,
                           targetHeight: Int = 0, audioOnly: Bool = false,
                           returnToHistory: Bool = false) {
        let store = Defaults.store
        store.set(Screen.player.rawValue, forKey: prefix + "screen")
        store.set((returnToHistory ? Screen.history : Screen.search).rawValue,
                  forKey: prefix + "return_screen")
        store.set(item.source, forKey: prefix + "source")
        store.set(item.title, forKey: prefix + "title")
        store.set(item.subtitle, forKey: prefix + "subtitle")
        store.set(item.thumbnail, forKey: prefix + "thumbnail")
        store.set(item.playUrl, forKey: prefix + "resolver_url")
        store.set(item.pageUrl, forKey: prefix + "page_url")
        store.set(item.durationMs, forKey: prefix + "duration")
        store.set(item.maxWidth, forKey: prefix + "max_width")
        store.set(item.maxHeight, forKey: prefix + "max_height")
        store.set(max(0, position), forKey: prefix + "position")
        store.set(trafficMode, forKey: prefix + "player_traffic_mode")
        store.set(targetHeight, forKey: prefix + "player_target_height")
        store.set(audioOnly, forKey: prefix + "player_audio_only")
    }

    static func savePlayerPosition(_ position: Int) {
        Defaults.store.set(max(0, position), forKey: prefix + "position")
    }

    static func savePlaybackSpeed(_ speed: Double) {
        Defaults.store.set(speed, forKey: prefix + "playback_speed")
    }

    static func markSearch() {
        Defaults.store.set(Screen.search.rawValue, forKey: prefix + "screen")
        Defaults.store.set(Screen.search.rawValue, forKey: prefix + "return_screen")
    }

    static func markHistory() {
        Defaults.store.set(Screen.history.rawValue, forKey: prefix + "screen")
        Defaults.store.set(Screen.history.rawValue, forKey: prefix + "return_screen")
    }

    static func markReturnScreen() {
        Defaults.store.set(returnScreen.rawValue, forKey: prefix + "screen")
    }

    static var screen: Screen {
        Screen(rawValue: Defaults.string(prefix + "screen", Screen.search.rawValue)) ?? .search
    }

    static var returnScreen: Screen {
        Screen(rawValue: Defaults.string(prefix + "return_screen", Screen.search.rawValue)) ?? .search
    }

    static var query: String { Defaults.string(prefix + "query") }
    static var filter: Int { Defaults.int(prefix + "filter") }
    static var trafficMode: Bool { Defaults.bool(prefix + "traffic_mode") }
    static var playerTrafficMode: Bool { Defaults.bool(prefix + "player_traffic_mode") }
    static var playerTargetHeight: Int { Defaults.int(prefix + "player_target_height") }
    static var playerAudioOnly: Bool { Defaults.bool(prefix + "player_audio_only") }
    static var position: Int { Defaults.int(prefix + "position") }
    static var playbackSpeed: Double { Defaults.double(prefix + "playback_speed", 1) }

    static var playerItem: VideoItem? {
        let playUrl = Defaults.string(prefix + "resolver_url")
        let pageUrl = Defaults.string(prefix + "page_url")
        if playUrl.isEmpty && pageUrl.isEmpty { return nil }
        return VideoItem(source: Defaults.string(prefix + "source", VideoSource.rutube),
                         title: Defaults.string(prefix + "title", "Видео"),
                         subtitle: Defaults.string(prefix + "subtitle"),
                         thumbnail: Defaults.string(prefix + "thumbnail"),
                         playUrl: playUrl,
                         pageUrl: pageUrl,
                         durationMs: Defaults.int(prefix + "duration"),
                         maxWidth: Defaults.int(prefix + "max_width"),
                         maxHeight: Defaults.int(prefix + "max_height"))
    }
}

/// Позиция просмотра по каждому ролику. Пишется только после первой минуты, чтобы
/// случайное открытие не засоряло список продолжения.
enum WatchProgressStore {
    static let minPositionMs = 60_000
    private static let prefix = "watch_progress."

    struct Progress {
        let positionMs: Int
        let durationMs: Int
    }

    static func save(source: String, pageUrl: String, positionMs: Int, durationMs: Int) {
        guard positionMs >= minPositionMs, !pageUrl.isEmpty else { return }
        let key = prefix + self.key(source: source, pageUrl: pageUrl)
        Defaults.store.set(positionMs, forKey: key + "_position")
        Defaults.store.set(max(0, durationMs), forKey: key + "_duration")
    }

    static func get(_ item: VideoItem) -> Progress {
        let key = prefix + self.key(source: item.source, pageUrl: item.pageUrl)
        let position = Defaults.int(key + "_position")
        let duration = Defaults.int(key + "_duration", item.durationMs)
        return position >= minPositionMs
            ? Progress(positionMs: position, durationMs: duration)
            : Progress(positionMs: 0, durationMs: duration)
    }

    static func clear(key: String) {
        let key = prefix + key
        Defaults.store.removeObject(forKey: key + "_position")
        Defaults.store.removeObject(forKey: key + "_duration")
    }

    static func key(source: String, pageUrl: String) -> String {
        let value = source + "|" + pageUrl
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// История просмотров: список ключей в порядке новизны плюс по записи на ролик.
enum WatchHistoryStore {
    private static let prefix = "watch_history."
    private static let orderKey = prefix + "order"
    private static let entryPrefix = prefix + "video_"
    private static let maxEntries = 1000

    struct Entry {
        let item: VideoItem
        let trafficMode: Bool
        let targetHeight: Int
        let audioOnly: Bool
        let lastWatchedAt: Date
    }

    static func record(_ item: VideoItem, trafficMode: Bool, targetHeight: Int, audioOnly: Bool) {
        guard !item.pageUrl.isEmpty else { return }
        let key = WatchProgressStore.key(source: item.source, pageUrl: item.pageUrl)
        let value: [String: Any] = [
            "s": item.source, "t": item.title, "u": item.subtitle, "i": item.thumbnail,
            "r": item.playUrl, "p": item.pageUrl, "d": item.durationMs,
            "w": item.maxWidth, "h": item.maxHeight,
            "m": trafficMode, "q": targetHeight, "a": audioOnly,
            "l": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let encoded = String(data: data, encoding: .utf8) else { return }

        var order = readOrder()
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
        Defaults.store.set(encoded, forKey: entryPrefix + key)
        while order.count > maxEntries {
            Defaults.store.removeObject(forKey: entryPrefix + order.removeLast())
        }
        Defaults.store.set(order.joined(separator: ","), forKey: orderKey)
    }

    static func load() -> [Entry] {
        var result: [Entry] = []
        for key in readOrder() {
            guard let encoded = Defaults.store.string(forKey: entryPrefix + key),
                  let value = try? JSON(parsing: encoded) else { continue }
            let item = VideoItem(source: value.string("s", VideoSource.rutube),
                                 title: value.string("t", "Видео"),
                                 subtitle: value.string("u"),
                                 thumbnail: value.string("i"),
                                 playUrl: value.string("r"),
                                 pageUrl: value.string("p"),
                                 durationMs: max(0, value.long("d")),
                                 maxWidth: max(0, value.int("w")),
                                 maxHeight: max(0, value.int("h")))
            guard !item.playUrl.isEmpty, !item.pageUrl.isEmpty else { continue }
            // Запись остаётся в истории, только пока есть сохранённая позиция.
            let progress = WatchProgressStore.get(item)
            guard progress.positionMs >= WatchProgressStore.minPositionMs else { continue }
            result.append(Entry(item: item,
                                trafficMode: value.bool("m"),
                                targetHeight: max(0, value.int("q")),
                                audioOnly: value.bool("a"),
                                lastWatchedAt: Date(timeIntervalSince1970: Double(max(0, value.long("l"))) / 1000)))
        }
        return result
    }

    static func contains(_ item: VideoItem) -> Bool {
        guard !item.pageUrl.isEmpty else { return false }
        let key = WatchProgressStore.key(source: item.source, pageUrl: item.pageUrl)
        return Defaults.store.object(forKey: entryPrefix + key) != nil
    }

    /// Полная очистка истории: записи, порядок и сохранённые позиции просмотра.
    static func clear() {
        for key in readOrder() {
            Defaults.store.removeObject(forKey: entryPrefix + key)
            WatchProgressStore.clear(key: key)
        }
        Defaults.store.removeObject(forKey: orderKey)
    }

    private static func readOrder() -> [String] {
        let encoded = Defaults.string(orderKey)
        if encoded.isEmpty { return [] }
        var result: [String] = []
        var seen = Set<String>()
        for value in encoded.split(separator: ",") {
            let key = String(value)
            if seen.insert(key).inserted { result.append(key) }
            if result.count == maxEntries { break }
        }
        return result
    }
}
