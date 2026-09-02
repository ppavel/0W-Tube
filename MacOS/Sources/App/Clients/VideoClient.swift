import Foundation

protocol VideoClient {
    func search(query: String) async throws -> [Video]
    func resolveStream(videoId: String) async throws -> URL?
}
