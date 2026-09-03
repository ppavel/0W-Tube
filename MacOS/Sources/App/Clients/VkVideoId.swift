import Foundation

/// Извлечение идентификатора `owner_id_video_id[_access_key]` из произвольных ссылок VK.
enum VkVideoId {
    static func fromUrl(_ url: String?) throws -> String {
        guard let url else { throw HttpError.message("Не найден ID VK Video") }
        if let id = findInText(url) {
            if hasAccessKey(id) { return id }
            let accessKey = queryAccessKey(url)
            return accessKey.isEmpty ? id : id + "_" + accessKey
        }
        let owner = Url.queryParameter(url, "oid")
        let video = Url.queryParameter(url, "id")
        if isSignedNumber(owner), isUnsignedNumber(video) {
            let accessKey = queryAccessKey(url)
            return owner! + "_" + video! + (accessKey.isEmpty ? "" : "_" + accessKey)
        }
        throw HttpError.message("Не найден ID VK Video")
    }

    static func fromVideo(_ video: JSON) -> String {
        let base = "\(video.long("owner_id"))_\(video.long("id"))"
        var accessKey = cleanAccessKey(video.string("access_key"))
        if accessKey.isEmpty { accessKey = cleanAccessKey(video.string("accessKey")) }
        if !accessKey.isEmpty { return base + "_" + accessKey }

        for field in ["direct_url", "share_url", "player"] {
            if let candidate = try? fromUrl(video.string(field)), candidate.hasPrefix(base + "_") {
                return candidate
            }
        }
        return base
    }

    private static func queryAccessKey(_ url: String) -> String {
        let accessKey = cleanAccessKey(Url.queryParameter(url, "access_key"))
        return accessKey.isEmpty ? cleanAccessKey(Url.queryParameter(url, "hash")) : accessKey
    }

    private static func hasAccessKey(_ id: String) -> Bool {
        guard let first = id.firstIndex(of: "_") else { return false }
        return id[id.index(after: first)...].contains("_")
    }

    private static func findInText(_ value: String) -> String? {
        let characters = Array(value)
        guard !characters.isEmpty else { return nil }
        var from = 0
        while from < characters.count {
            guard let marker = indexOf("video", in: characters, from: from) else { return nil }
            let start = marker + 5
            var cursor = start
            if cursor < characters.count && characters[cursor] == "-" { cursor += 1 }
            let ownerStart = cursor
            while cursor < characters.count && isDigit(characters[cursor]) { cursor += 1 }
            if cursor > ownerStart && cursor < characters.count && characters[cursor] == "_" {
                cursor += 1
                let videoStart = cursor
                while cursor < characters.count && isDigit(characters[cursor]) { cursor += 1 }
                if cursor > videoStart {
                    if cursor < characters.count && characters[cursor] == "_" {
                        cursor += 1
                        let accessStart = cursor
                        while cursor < characters.count && isAccessKeyChar(characters[cursor]) { cursor += 1 }
                        if cursor == accessStart { cursor -= 1 }
                    }
                    return String(characters[start..<cursor])
                }
            }
            from = marker + 5
        }
        return nil
    }

    private static func indexOf(_ needle: String, in characters: [Character], from: Int) -> Int? {
        let pattern = Array(needle)
        guard characters.count >= pattern.count else { return nil }
        var index = max(0, from)
        while index + pattern.count <= characters.count {
            if Array(characters[index..<(index + pattern.count)]) == pattern { return index }
            index += 1
        }
        return nil
    }

    private static func cleanAccessKey(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let characters = Array(value)
        var end = 0
        while end < characters.count && isAccessKeyChar(characters[end]) { end += 1 }
        return end == 0 ? "" : String(characters[0..<end])
    }

    private static func isSignedNumber(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let body = value.hasPrefix("-") ? String(value.dropFirst()) : value
        return !body.isEmpty && body.allSatisfy(isDigit)
    }

    private static func isUnsignedNumber(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.allSatisfy(isDigit)
    }

    private static func isDigit(_ value: Character) -> Bool { value >= "0" && value <= "9" }

    private static func isAccessKeyChar(_ value: Character) -> Bool {
        isDigit(value) || (value >= "a" && value <= "z") || (value >= "A" && value <= "Z")
            || value == "-" || value == "_"
    }
}
