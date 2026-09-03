import Foundation
import SwiftUI

struct PlaybackRequest: Identifiable {
    let item: VideoItem
    let resumeMs: Int
    let trafficMode: Bool
    let targetHeight: Int
    let audioOnly: Bool

    var id: String { item.stableKey }
}

@MainActor
final class SearchViewModel: ObservableObject {
    static let normalFilterLabels = ["Любое", "720+", "1080+", "1440+", "2160 / 4K"]
    static let normalFilterWidths = [0, 1280, 1920, 2560, 3840]
    static let trafficFilterLabels = ["HD+", "480", "360", "240", "144", "Звук"]
    static let trafficFilterWidths = [1280, 854, 640, 426, 256, 0]
    static let trafficFilterHeights = [720, 480, 360, 240, 144, 0]

    private static let thumbnailTargetWidth = 480

    @Published var query = ""
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var status = ""
    @Published private(set) var sourceErrors: [String] = []
    @Published private(set) var searchStarted = false
    @Published private(set) var selectedFilter = 0
    @Published private(set) var trafficMode = false
    @Published private(set) var historyMode = false
    @Published var playback: PlaybackRequest?

    /// Полная выдача до фильтра по качеству: смена фильтра пересобирает список
    /// локально и никогда не перезапускает поиск по бэкендам.
    private var allItems: [VideoItem] = []
    private var historyItems: [VideoItem] = []
    private var historyByKey: [String: WatchHistoryStore.Entry] = [:]
    private var currentSearchQuery = ""

    /// Номер поколения поиска: результат, чьё поколение устарело, отбрасывается.
    /// Другого механизма отмены в исходном приложении нет.
    private var generation = 0
    private var activeSearches: [Task<Void, Never>] = []
    private var qualityRequested = Set<String>()
    private var qualityJobs = 0
    private var sourcesDone: Set<String> = []
    private var sourceCounts: [String: Int] = [:]
    private var sourceFailures: [String: String] = [:]

    private static let primarySources = [VideoSource.rutube, VideoSource.vk,
                                         VideoSource.dzen, VideoSource.ok]
    private static let allSources = primarySources + [VideoSource.peerTube]

    var filterLabels: [String] { trafficMode ? Self.trafficFilterLabels : Self.normalFilterLabels }

    // MARK: - Восстановление состояния

    func restore() {
        query = StateStore.query
        trafficMode = StateStore.trafficMode
        selectedFilter = min(max(0, StateStore.filter), filterLabels.count - 1)
        reloadHistory()
        if StateStore.screen == .history || StateStore.returnScreen == .history {
            historyMode = !historyItems.isEmpty
            if historyMode { items = historyItems }
        }
    }

    func reloadHistory() {
        let entries = WatchHistoryStore.load()
        historyItems = entries.map(\.item)
        historyByKey = Dictionary(entries.map { ($0.item.stableKey, $0) },
                                  uniquingKeysWith: { first, _ in first })
        if historyMode { items = historyItems }
    }

    // MARK: - Поиск

    func search() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return }
        searchStarted = true
        generation += 1
        let current = generation
        currentSearchQuery = value

        for task in activeSearches { task.cancel() }
        activeSearches.removeAll()
        allItems.removeAll()
        qualityRequested.removeAll()
        qualityJobs = 0
        sourcesDone.removeAll()
        sourceCounts.removeAll()
        sourceFailures.removeAll()
        if !historyMode { items.removeAll() }
        StateStore.saveSearch(query: value, filter: selectedFilter, trafficMode: trafficMode)
        if historyMode { StateStore.markHistory() } else { StateStore.markSearch() }
        updateStatus()

        activeSearches.append(Task { [weak self] in
            await self?.runSource(current, VideoSource.rutube) {
                try await SearchClient.searchRutube(query: value, minWidth: 0)
            }
        })
        activeSearches.append(Task { [weak self] in
            await self?.runPagedSource(current, VideoSource.vk) { onPage in
                try await SearchClient.searchVkPages(query: value, minWidth: 0,
                                                     thumbnailWidth: Self.thumbnailTargetWidth,
                                                     onPage: onPage)
            }
        })
        activeSearches.append(Task { [weak self] in
            await self?.runPagedSource(current, VideoSource.dzen) { onPage in
                try await SearchClient.searchDzenPages(query: value, onPage: onPage)
            }
        })
        activeSearches.append(Task { [weak self] in
            await self?.runSource(current, VideoSource.ok) {
                try await SearchClient.searchOk(query: value, minWidth: 0)
            }
        })
        // PeerTube — вспомогательный источник и заметно медленнее остальных. В Java он
        // отправляется последним в пул из четырёх потоков и потому физически не может
        // задержать первые карточки; здесь пула нет, поэтому ожидание выражено явно.
        activeSearches.append(Task { [weak self] in
            await self?.waitForFirstPrimarySource(current)
            await self?.runSource(current, VideoSource.peerTube) {
                try await SearchClient.searchPeerTube(query: value, minWidth: 0,
                                                      thumbnailWidth: Self.thumbnailTargetWidth)
            }
        })
    }

    private func waitForFirstPrimarySource(_ current: Int) async {
        while generation == current && sourcesDone.isDisjoint(with: Self.primarySources) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
        }
    }

    private func runSource(_ current: Int, _ source: String,
                           _ call: @Sendable () async throws -> [VideoItem]) async {
        do {
            let found = try await call()
            guard current == generation else { return }
            deliver(found, current: current)
            finishSource(source, count: found.count, error: nil)
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            finishSource(source, count: 0, error: message(error))
        }
    }

    private func runPagedSource(_ current: Int, _ source: String,
                                _ call: (@escaping ([VideoItem]) async -> Bool) async throws -> Int) async {
        var delivered = 0
        do {
            let count = try await call { [weak self] page in
                guard let self, current == self.generation, !Task.isCancelled else { return false }
                delivered += page.count
                self.deliver(page, current: current)
                return true
            }
            guard current == generation else { return }
            finishSource(source, count: count, error: nil)
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            finishSource(source, count: delivered, error: message(error))
        }
    }

    private func deliver(_ found: [VideoItem], current: Int) {
        guard !found.isEmpty else { return }
        allItems.append(contentsOf: found)
        refreshDisplayedItems()
        requestMissingQualities(current, found)
    }

    private func finishSource(_ source: String, count: Int, error: String?) {
        sourcesDone.insert(source)
        sourceCounts[source] = count
        sourceFailures[source] = error
        updateStatus()
    }

    // MARK: - Фильтры и отображение

    func selectFilter(_ index: Int) {
        selectedFilter = max(0, min(index, filterLabels.count - 1))
        StateStore.saveSearch(query: query, filter: selectedFilter, trafficMode: trafficMode)
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
        refreshDisplayedItems()
        if selectedFilter > 0 { requestMissingQualities(generation, allItems) }
    }

    func toggleTrafficMode() {
        trafficMode.toggle()
        selectedFilter = 0
        StateStore.saveSearch(query: query, filter: selectedFilter, trafficMode: trafficMode)
        refreshDisplayedItems()
        if !allItems.isEmpty { requestMissingQualities(generation, allItems) }
    }

    func toggleHistoryMode() {
        historyMode.toggle()
        if historyMode {
            reloadHistory()
            items = historyItems
            StateStore.markHistory()
        } else {
            StateStore.markSearch()
            refreshDisplayedItems()
        }
        updateStatus()
    }

    private func refreshDisplayedItems() {
        let minWidth = trafficMode
            ? Self.trafficFilterWidths[selectedFilter]
            : Self.normalFilterWidths[selectedFilter]
        let filtered = minWidth == 0 ? allItems : allItems.filter { $0.maxWidth >= minWidth }
        let sorted = VideoRanker.sort(filtered, query: currentSearchQuery, lowestQualityFirst: trafficMode)
        if !historyMode { items = sorted }
        cachedSearchCount = sorted.count
        updateStatus()
    }

    private var cachedSearchCount = 0

    private func updateStatus() {
        sourceErrors = Self.allSources.compactMap { source in
            guard let error = sourceFailures[source] ?? nil else { return nil }
            return "\(VideoSource.label(source)): \(error)"
        }
        guard searchStarted else {
            status = historyMode ? "История: \(historyItems.count)" : ""
            return
        }
        if historyMode {
            status = "История: \(historyItems.count)"
            return
        }
        let working = !Self.allSources.allSatisfy(sourcesDone.contains) || qualityJobs > 0
        status = "Найдено: \(cachedSearchCount)" + (working ? "…" : "")
    }

    // MARK: - Догрузка качества

    private func requestMissingQualities(_ current: Int, _ candidates: [VideoItem]) {
        var regular: [VideoItem] = []
        var dzen: [VideoItem] = []
        var ok: [VideoItem] = []
        for item in candidates {
            guard item.maxWidth == 0, qualityRequested.insert(item.stableKey).inserted else { continue }
            switch item.source {
            case VideoSource.dzen: dzen.append(item)
            case VideoSource.ok: ok.append(item)
            default: regular.append(item)
            }
        }
        // Дзен и OK чувствительны к параллельным обращениям к плееру, им — по две.
        submitQualityJob(current, regular, parallel: 4)
        submitQualityJob(current, dzen, parallel: 2)
        submitQualityJob(current, ok, parallel: 2)
    }

    private func submitQualityJob(_ current: Int, _ missing: [VideoItem], parallel: Int) {
        guard !missing.isEmpty else { return }
        qualityJobs += 1
        updateStatus()
        // `Task` внутри @MainActor-класса наследует главный актор, поэтому
        // результат применяется без дополнительного переключения контекста.
        activeSearches.append(Task { [weak self] in
            let inspected = await SearchClient.inspectQualities(missing, maxParallelRequests: parallel)
            guard let self, !Task.isCancelled, current == self.generation else { return }
            var byKey: [String: VideoItem] = [:]
            for item in inspected { byKey[item.stableKey] = item }
            for index in self.allItems.indices {
                if let replacement = byKey[self.allItems[index].stableKey] {
                    self.allItems[index] = replacement
                }
            }
            self.qualityJobs = max(0, self.qualityJobs - 1)
            self.refreshDisplayedItems()
        })
    }

    // MARK: - Воспроизведение

    func play(_ item: VideoItem) {
        let watched = WatchProgressStore.get(item)
        var position = watched.positionMs
        let duration = watched.durationMs > 0 ? watched.durationMs : item.durationMs
        // Досмотренное до конца открывается заново, а не на последних секундах.
        if duration > 0 && position * 100 >= duration * 95 { position = 0 }

        let history = historyMode ? historyByKey[item.stableKey] : nil
        let playerTrafficMode = history?.trafficMode ?? trafficMode
        let targetHeight = history?.targetHeight
            ?? (trafficMode ? Self.trafficFilterHeights[selectedFilter] : 0)
        // Нулевая целевая высота в режиме экономии — это фильтр «Звук».
        let audioOnly = history?.audioOnly ?? (trafficMode && targetHeight == 0)

        // Уже начатый ролик поднимается в истории сразу при открытии, не дожидаясь
        // следующего сохранения позиции.
        if watched.positionMs >= WatchProgressStore.minPositionMs {
            WatchHistoryStore.record(item.withDuration(duration), trafficMode: playerTrafficMode,
                                     targetHeight: targetHeight, audioOnly: audioOnly)
        }
        StateStore.savePlayer(item: item, position: position, trafficMode: playerTrafficMode,
                              targetHeight: targetHeight, audioOnly: audioOnly,
                              returnToHistory: historyMode)
        playback = PlaybackRequest(item: item, resumeMs: position, trafficMode: playerTrafficMode,
                                   targetHeight: targetHeight, audioOnly: audioOnly)
    }

    func savePlaybackProgress(_ request: PlaybackRequest, positionMs: Int, durationMs: Int) {
        WatchProgressStore.save(source: request.item.source, pageUrl: request.item.pageUrl,
                                positionMs: positionMs, durationMs: durationMs)
        StateStore.savePlayerPosition(positionMs)
        if positionMs >= WatchProgressStore.minPositionMs {
            WatchHistoryStore.record(request.item.withDuration(durationMs > 0 ? durationMs : request.item.durationMs),
                                     trafficMode: request.trafficMode,
                                     targetHeight: request.targetHeight,
                                     audioOnly: request.audioOnly)
        }
    }

    func finishPlayback() {
        playback = nil
        StateStore.markReturnScreen()
        reloadHistory()
    }

    private func message(_ error: Error) -> String { HttpError.describe(error) }
}
