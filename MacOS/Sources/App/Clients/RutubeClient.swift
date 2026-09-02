import Foundation

struct RutubeClient: VideoClient {
    func search(query: String) async throws -> [Video] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://rutube.ru/api/search/video/?query=\(encodedQuery)"
        
        guard let url = URL(string: urlString) else { return [] }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:120.0) Gecko/20100101 Firefox/120.0", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]] {
            return results.compactMap { dict in
                guard let id = dict["id"] as? String,
                      let title = dict["title"] as? String else { return nil }
                
                let thumbString = dict["thumbnail_url"] as? String
                let thumbUrl = thumbString.flatMap { URL(string: $0) }
                
                return Video(id: id, title: title, thumbnailUrl: thumbUrl, source: "RUTUBE")
            }
        }
        return []
    }
    
    func resolveStream(videoId: String) async throws -> URL? {
        // Правильный endpoint из оригинального Java-кода
        let urlString = "https://rutube.ru/api/play/options/\(videoId)/?format=json&no_404=true&mq=all"
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:120.0) Gecko/20100101 Firefox/120.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://rutube.ru/video/\(videoId)/", forHTTPHeaderField: "Referer")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Отладочный вывод
        if let jsonString = String(data: data, encoding: .utf8) {
            print("\n=== RUTUBE STREAM RESPONSE ===")
            print("Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            print(jsonString.prefix(500))
            print("================================\n")
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Проверяем наличие ошибки
            if let detail = json["detail"] as? [String: Any],
               let reason = detail["type"] as? String {
                print("RUTUBE error: \(reason)")
                return nil
            }
            
            // Извлекаем video_balancer
            if let balancer = json["video_balancer"] as? [String: Any] {
                // Ищем HLS (m3u8) ссылку
                for (_, value) in balancer {
                    if let urlString = value as? String,
                       urlString.contains(".m3u8") || urlString.contains("ct=8"),
                       let m3u8Url = URL(string: urlString) {
                        print("Found HLS stream: \(urlString)")
                        return m3u8Url
                    }
                }
                
                // Если HLS не найден, ищем DASH (mpd)
                for (_, value) in balancer {
                    if let urlString = value as? String,
                       urlString.contains(".mpd") || urlString.contains("ct=6"),
                       let dashUrl = URL(string: urlString) {
                        print("Found DASH stream: \(urlString)")
                        return dashUrl
                    }
                }
                
                // Fallback: любая HTTP ссылка
                for (_, value) in balancer {
                    if let urlString = value as? String,
                       urlString.hasPrefix("http"),
                       let fallbackUrl = URL(string: urlString) {
                        print("Found fallback stream: \(urlString)")
                        return fallbackUrl
                    }
                }
            }
        }
        
        return nil
    }
}