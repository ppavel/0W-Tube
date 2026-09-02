import Foundation

struct Video: Identifiable, Hashable {
    let id: String
    let title: String
    let thumbnailUrl: URL?
    let source: String
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
