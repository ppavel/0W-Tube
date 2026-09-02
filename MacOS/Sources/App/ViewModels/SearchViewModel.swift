import Foundation
import SwiftUI

@MainActor
class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [Video] = []
    @Published var isLoading: Bool = false
    @Published var selectedVideo: Video?
    
    private let client: VideoClient = RutubeClient()
    
    func search() async {
        guard !query.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        
        do {
            results = try await client.search(query: query)
        } catch {
            print("Search error: \(error)")
            results = []
        }
    }
    
    func getStreamUrl(for video: Video) async -> URL? {
        do {
            return try await client.resolveStream(videoId: video.id)
        } catch {
            print("Resolve stream error: \(error)")
            return nil
        }
    }
}
