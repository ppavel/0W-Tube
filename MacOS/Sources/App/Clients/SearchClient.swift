import Foundation

/// Фасад над бэкендами и общий механизм догрузки качества.
enum SearchClient {
    static func searchRutube(query: String, minWidth: Int) async throws -> [VideoItem] {
        try await RutubeClient.search(query: query, minWidth: minWidth)
    }

    static func searchVk(query: String, minWidth: Int, thumbnailWidth: Int = 480) async throws -> [VideoItem] {
        try await VkWebClient.search(query: query, minWidth: minWidth, thumbnailWidth: thumbnailWidth)
    }

    static func searchVkPages(query: String, minWidth: Int, thumbnailWidth: Int,
                              onPage: ([VideoItem]) async -> Bool) async throws -> Int {
        try await VkWebClient.searchPages(query: query, minWidth: minWidth,
                                          thumbnailWidth: thumbnailWidth, onPage: onPage)
    }

    static func searchDzen(query: String, minWidth: Int) async throws -> [VideoItem] {
        try await DzenClient.search(query: query, minWidth: minWidth)
    }

    static func searchDzenPages(query: String, onPage: ([VideoItem]) async -> Bool) async throws -> Int {
        try await DzenClient.searchPages(query: query, onPage: onPage)
    }

    static func searchOk(query: String, minWidth: Int) async throws -> [VideoItem] {
        try await OkClient.search(query: query, minWidth: minWidth)
    }

    static func searchPeerTube(query: String, minWidth: Int, thumbnailWidth: Int) async throws -> [VideoItem] {
        try await PeerTubeClient.search(query: query, minWidth: minWidth, thumbnailWidth: thumbnailWidth)
    }

    static func filterByQuality(_ candidates: [VideoItem], minWidth: Int,
                                maxParallelRequests: Int = 4) async throws -> [VideoItem] {
        let inspected = await inspectQualities(candidates, maxParallelRequests: maxParallelRequests)
        return inspected.filter { $0.maxWidth >= minWidth }
    }

    /// Догружает реальное максимальное разрешение для карточек, которые источник отдал
    /// без него. Число одновременных проверок ограничено: сервисы плохо реагируют на
    /// пачку запросов к плееру, а карточки уже показаны и обновляются на месте.
    /// Ролики, чей поток проверить не удалось, из результата выпадают и сохраняют
    /// прежнее (неизвестное) качество.
    static func inspectQualities(_ candidates: [VideoItem], maxParallelRequests: Int) async -> [VideoItem] {
        if candidates.isEmpty { return [] }
        let workers = max(1, min(maxParallelRequests, candidates.count))
        return await withTaskGroup(of: VideoItem?.self) { group in
            var index = 0
            var result: [VideoItem] = []
            func addNext() {
                guard index < candidates.count else { return }
                let item = candidates[index]
                index += 1
                group.addTask {
                    guard let info = try? await StreamResolver.inspect(item.playUrl) else { return nil }
                    return item.withQuality(info.maxWidth, info.maxHeight)
                }
            }
            for _ in 0..<workers { addNext() }
            while let finished = await group.next() {
                if Task.isCancelled { group.cancelAll() }
                if let finished { result.append(finished) }
                addNext()
            }
            return result
        }
    }
}
