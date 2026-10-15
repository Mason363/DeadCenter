import Foundation
import DCModel

/// Fetches a web page and reduces it to its article; non-HTML responses go to their own reader.
enum WebReader {
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func read(_ url: URL, into emitter: BlockEmitter) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw IngestError.unsupported("\(url.scheme ?? "these") links")
        }
        let (data, response) = try await fetch(url)
        let finalURL = response.url ?? url
        let mime = response.mimeType?.lowercased() ?? ""
        let host = finalURL.host ?? url.absoluteString

        if mime.contains("html") || ((mime.isEmpty || mime == "application/octet-stream") && DocumentFormat.sniff(data) == .html) {
            let html = TextDecoding.decodeHTML(data, transportCharset: response.textEncodingName)
            try readHTML(html, url: finalURL, into: emitter)
        } else if mime.hasPrefix("text/plain") {
            let text = TextDecoding.decode(data, declared: response.textEncodingName.flatMap(TextDecoding.encoding(ianaName:)))
            let name = finalURL.deletingPathExtension().lastPathComponent
            if finalURL.pathExtension.lowercased().hasPrefix("md") || MarkdownReader.looksLikeMarkdown(text) {
                try MarkdownReader.read(text, baseURL: finalURL, fallbackTitle: name.isEmpty ? host : name, into: emitter)
            } else {
                emitter.title(name.isEmpty ? host : name)
                try PlainTextReader.read(text, into: emitter)
            }
        } else if mime.contains("markdown") {
            let text = TextDecoding.decode(data, declared: response.textEncodingName.flatMap(TextDecoding.encoding(ianaName:)))
            try MarkdownReader.read(text, baseURL: finalURL, fallbackTitle: finalURL.deletingPathExtension().lastPathComponent, into: emitter)
        } else {
            try await DocumentRouter.readDownloaded(data, mimeType: mime.isEmpty ? nil : mime,
                                                    suggestedName: finalURL.lastPathComponent, fallbackTitle: host, into: emitter)
        }
    }

    /// The article in an already-fetched page.
    static func readHTML(_ html: String, url: URL, into emitter: BlockEmitter) throws {
        try HTMLDocumentReader.read(html: html, baseURL: url, resolver: URLImageResolver(baseURL: url), mode: .article,
                                    fallbackTitle: url.host, into: emitter)
    }

    private static func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,application/pdf,*/*;q=0.8",
            "Accept-Language": acceptLanguage,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw IngestError.network(message(for: error))
        }
        guard let http = response as? HTTPURLResponse else { throw IngestError.network("the server's response wasn't understood.") }
        guard (200..<300).contains(http.statusCode) else {
            let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw IngestError.network("the server answered “\(reason)” (\(http.statusCode)).")
        }
        guard !data.isEmpty else { throw IngestError.empty }
        return (data, http)
    }

    private static var acceptLanguage: String {
        let languages = Locale.preferredLanguages.prefix(3)
        let weighted = languages.enumerated().map { i, lang in i == 0 ? lang : "\(lang);q=\(String(format: "%.1f", 1 - Double(i) * 0.2))" }
        return (weighted + ["en;q=0.5"]).joined(separator: ", ")
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: "you appear to be offline."
        case .timedOut: "the site took too long to respond."
        case .cannotFindHost, .dnsLookupFailed: "the site couldn't be found."
        case .cannotConnectToHost: "the site refused the connection."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: "a secure connection couldn't be made."
        case .badURL, .unsupportedURL: "the address isn't valid."
        case .httpTooManyRedirects: "the site redirected too many times."
        default: error.localizedDescription
        }
    }
}
