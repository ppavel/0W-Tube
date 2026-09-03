import Foundation

enum HttpError: LocalizedError {
    case badUrl(String)
    case status(String, Int)
    case tooLarge(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badUrl(let value): return "Неверный адрес: \(value)"
        case .status(let prefix, let code): return prefix.isEmpty ? "HTTP \(code)" : "\(prefix): HTTP \(code)"
        case .tooLarge(let prefix): return "Ответ \(prefix) слишком большой"
        case .message(let value): return value
        }
    }

    /// Текст для статусной строки. `URLError` описывает себя по-английски и на языке
    /// системы, а весь интерфейс здесь русский, поэтому сетевые сбои переводятся сами.
    static func describe(_ error: Error) -> String {
        if let http = error as? HttpError { return http.errorDescription ?? "ошибка" }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "превышено время ожидания"
            case .notConnectedToInternet: return "нет подключения к сети"
            case .networkConnectionLost: return "соединение разорвано"
            case .cannotFindHost, .dnsLookupFailed: return "сервер не найден"
            case .cannotConnectToHost: return "сервер не отвечает"
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "ошибка защищённого соединения"
            case .badServerResponse: return "неверный ответ сервера"
            case .cancelled: return "запрос отменён"
            default: return "сетевая ошибка \(url.code.rawValue)"
            }
        }
        if error is DecodingError { return "не удалось разобрать ответ" }
        // Битый JSON от сервиса прилетает как NSCocoaErrorDomain 3840.
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == 3840 {
            return "не удалось разобрать ответ"
        }
        let text = cocoa.localizedDescription
        return text.isEmpty ? "ошибка" : text
    }
}

/// Обёртка над `URLSession`, повторяющая поведение `HttpURLConnection` из Java-клиентов:
/// явные заголовки на каждый запрос, отключаемое следование редиректам и ручное
/// управление cookie (Дзен хранит анонимную сессию сам, а не через общий стор).
enum Http {
    /// Java-код читает ответ целиком в память и обрывает чтение по лимиту. На macOS
    /// нет 192-мегабайтного heap-а Android TV, поэтому лимит проверяется по факту:
    /// сообщение об ошибке для слишком больших ответов остаётся тем же.
    static let noLimit = Int.max

    private static let followingSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static let redirectBlocker = RedirectBlocker()

    private static let plainSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }()

    struct Response {
        let text: String
        let statusCode: Int
        let headers: [String: String]
        /// Пары `name=value` из `Set-Cookie`. `allHeaderFields` склеивает несколько
        /// заголовков в один через запятую, поэтому разбор отдан `HTTPCookie`, а не
        /// ручному `split(",")`, который ломается о даты в `Expires`.
        let setCookies: [(name: String, value: String)]
        let finalUrl: URL
    }

    struct Options {
        var method = "GET"
        var body: Data?
        var accept = "application/json,text/html,*/*"
        var acceptLanguage: String?
        var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15) AppleWebKit/537.36"
        var referer: String?
        var origin: String?
        var contentType: String?
        var extraHeaders: [String: String] = [:]
        var cookie: String?
        var timeout: TimeInterval = 8
        var limit = Http.noLimit
        var followRedirects = true
        /// Префикс в тексте ошибки, повторяющий `"RUTUBE: HTTP 404"` из Java.
        var errorPrefix = ""
    }

    static func request(_ address: String, _ options: Options) async throws -> Response {
        guard let url = URL(string: address) else { throw HttpError.badUrl(address) }
        var request = URLRequest(url: url)
        request.httpMethod = options.method
        request.httpBody = options.body
        request.timeoutInterval = options.timeout
        request.httpShouldHandleCookies = false
        request.setValue(options.accept, forHTTPHeaderField: "Accept")
        request.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
        if let value = options.acceptLanguage { request.setValue(value, forHTTPHeaderField: "Accept-Language") }
        if let value = options.referer, !value.isEmpty { request.setValue(value, forHTTPHeaderField: "Referer") }
        if let value = options.origin { request.setValue(value, forHTTPHeaderField: "Origin") }
        if let value = options.contentType { request.setValue(value, forHTTPHeaderField: "Content-Type") }
        if let value = options.cookie, !value.isEmpty { request.setValue(value, forHTTPHeaderField: "Cookie") }
        for (name, value) in options.extraHeaders { request.setValue(value, forHTTPHeaderField: name) }

        let session = options.followRedirects ? followingSession : plainSession
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw HttpError.message("Пустой ответ: \(address)")
        }
        if data.count > options.limit {
            throw HttpError.tooLarge(options.errorPrefix.isEmpty ? "сервера" : options.errorPrefix)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name.lowercased()] = value
        }
        var setCookies: [(name: String, value: String)] = []
        if let fields = http.allHeaderFields as? [String: String] {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
                setCookies.append((cookie.name, cookie.value))
            }
        }
        return Response(text: decode(data, http),
                        statusCode: http.statusCode,
                        headers: headers,
                        setCookies: setCookies,
                        finalUrl: http.url ?? url)
    }

    static func text(_ address: String, _ options: Options) async throws -> String {
        let response = try await request(address, options)
        guard (200..<300).contains(response.statusCode) else {
            throw HttpError.status(options.errorPrefix, response.statusCode)
        }
        return response.text
    }

    static func json(_ address: String, _ options: Options) async throws -> JSON {
        try JSON(parsing: try await text(address, options))
    }

    /// Аналог `setRequestMethod("HEAD")` с включёнными редиректами: возвращает конечный URL.
    static func resolveRedirects(_ address: String, _ options: Options) async throws -> String {
        var head = options
        head.method = "HEAD"
        head.followRedirects = true
        let response = try await request(address, head)
        guard (200..<400).contains(response.statusCode) else {
            throw HttpError.status(options.errorPrefix, response.statusCode)
        }
        return response.finalUrl.absoluteString
    }

    private static func decode(_ data: Data, _ response: HTTPURLResponse) -> String {
        // Часть эндпоинтов VK отвечает в windows-1251; Java читает кодировку из
        // Content-Type, здесь это делает сам URLResponse.
        if let name = response.textEncodingName {
            let encoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding(name as CFString))
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) {
                return text
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

enum Url {
    /// Аналог `Uri.encode` / `URLEncoder.encode(...).replace("+", "%20")`.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Аналог `Uri.parse(url).getQueryParameter(name)`.
    static func queryParameter(_ address: String?, _ name: String) -> String? {
        guard let address, let components = URLComponents(string: address) else { return nil }
        return components.queryItems?.first { $0.name == name }?.value
    }

    /// Аналог `new URL(new URL(base), value)`: разрешает относительную ссылку.
    static func resolve(_ value: String, base: String?) -> String? {
        if value.isEmpty { return nil }
        if let base, !base.isEmpty, let baseUrl = URL(string: base) {
            return URL(string: value, relativeTo: baseUrl)?.absoluteURL.absoluteString
        }
        return URL(string: value)?.absoluteString
    }

    /// Аналог `httpUrl(...)`: `//host/...` дополняется схемой, всё не-HTTP отбрасывается.
    static func http(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("//") { return "https:" + value }
        return value.hasPrefix("http") ? value : nil
    }

    /// Аналог `origin(address)` из PeerTubeClient: только https, с портом при наличии.
    static func httpsOrigin(_ address: String) throws -> String {
        guard let components = URLComponents(string: address),
              components.scheme?.lowercased() == "https",
              let host = components.host else {
            throw HttpError.message("Неверный адрес PeerTube")
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "https://\(host)\(port)/"
    }
}
