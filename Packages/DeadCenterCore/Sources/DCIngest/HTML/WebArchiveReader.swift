import Foundation
import DCModel

/// Safari `.webarchive`: a property list holding the page's main resource and its subresources.
enum WebArchiveReader {
    static func read(url: URL, into emitter: BlockEmitter) async throws {
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any],
              let body = main["WebResourceData"] as? Data
        else { throw IngestError.unreadable("the web archive is damaged.") }

        let mime = (main["WebResourceMIMEType"] as? String)?.lowercased() ?? "text/html"
        let pageURL = (main["WebResourceURL"] as? String).flatMap(URL.init(string:))
        let charset = main["WebResourceTextEncodingName"] as? String
        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        if mime.hasPrefix("text/plain") {
            emitter.title(fallbackTitle)
            try PlainTextReader.read(TextDecoding.decode(body, declared: charset.flatMap(TextDecoding.encoding(ianaName:))), into: emitter)
            return
        }
        if !mime.contains("html") && !mime.contains("xml") {
            // A web archive of a PDF or image: hand the bytes to the matching reader.
            try await DocumentRouter.readDownloaded(body, mimeType: mime, suggestedName: pageURL?.lastPathComponent,
                                                    fallbackTitle: fallbackTitle, into: emitter)
            return
        }

        var resources: [String: Data] = [:]
        for resource in plist["WebSubresources"] as? [[String: Any]] ?? [] {
            guard let urlString = resource["WebResourceURL"] as? String,
                  let bytes = resource["WebResourceData"] as? Data,
                  (resource["WebResourceMIMEType"] as? String)?.lowercased().hasPrefix("image/") ?? true
            else { continue }
            resources[urlString] = bytes
        }
        let html = TextDecoding.decodeHTML(body, transportCharset: charset)
        let resolver = WebArchiveImageResolver(base: URLImageResolver(baseURL: pageURL), resources: resources)
        try HTMLDocumentReader.read(html: html, baseURL: pageURL, resolver: resolver, mode: .article,
                                    fallbackTitle: fallbackTitle, into: emitter)
    }
}
