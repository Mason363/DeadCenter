import Foundation
import DCModel

/// Reads an HTML document: optionally reduces it to its article with Readability, then walks it.
enum HTMLDocumentReader {
    enum Mode {
        /// Walk the markup as given (extension output, pasteboard fragments, EPUB chapters).
        case direct
        /// Run Readability first; fall back to walking the whole page without its chrome.
        case article
        /// `article` for documents that look like saved web pages, `direct` otherwise.
        case automatic
    }

    static func read(html: String, baseURL: URL?, resolver: any ImageResolver, mode: Mode,
                     fallbackTitle: String?, into emitter: BlockEmitter) throws {
        let document = HTMLParser.parse(html)
        try Task.checkCancellation()
        let pageTitle = document.documentTitle

        let wantsArticle = switch mode {
        case .direct: false
        case .article: true
        case .automatic: looksLikeWebPage(document)
        }

        if wantsArticle, let article = Readability.extract(wellFormedHTML: document.wellFormedDocument(), url: baseURL),
           article.textLength >= 140 {
            try Task.checkCancellation()
            let walker = HTMLBlockWalker(options: .init(resolver: resolver))
            let blocks = walker.walk(HTMLParser.parse(article.contentHTML))
            if blocks.contains(where: \.isReadableText) {
                let headline = document.first { $0.localName == "h1" }.map { TextNormalizer.clean($0.textContent) }
                emitter.title(articleTitle(article.title ?? pageTitle, siteName: article.siteName, headline: headline) ?? fallbackTitle)
                emitter.emit(blocks)
                emitter.progress(1)
                return
            }
        }

        emitter.title(pageTitle ?? fallbackTitle)
        let walker = HTMLBlockWalker(options: .init(resolver: resolver, skipsPageChrome: mode != .direct))
        emitter.emit(walker.walk(document))
        emitter.progress(1)
    }

    /// Drops the site name from a page title: "Story | Site" → "Story".
    static func articleTitle(_ raw: String?, siteName: String?, headline: String?) -> String? {
        guard let title = raw.map({ TextNormalizer.clean($0) }), !title.isEmpty else { return headline }
        let separators = [" | ", " - ", " – ", " — ", " · ", " :: ", " » ", " / "]
        if let headline, !headline.isEmpty, title != headline, title.hasPrefix(headline) || title.hasSuffix(headline) {
            let rest = title.hasPrefix(headline) ? title.dropFirst(headline.count) : title.dropLast(headline.count)
            if separators.contains(where: { rest.hasPrefix($0) || rest.hasSuffix($0) }) { return headline }
        }
        if let site = siteName.map({ TextNormalizer.clean($0) }), !site.isEmpty, site != title {
            for separator in separators {
                if title.hasSuffix(separator + site) { return String(title.dropLast(separator.count + site.count)) }
                if title.hasPrefix(site + separator) { return String(title.dropFirst(separator.count + site.count)) }
            }
        }
        return title
    }

    /// Saved pages carry scripts, navigation, or social metadata; authored documents don't.
    static func looksLikeWebPage(_ document: HTMLElement) -> Bool {
        var scripts = 0
        var chrome = false
        var social = false
        func scan(_ element: HTMLElement) {
            for child in element.elementChildren {
                switch child.localName {
                case "script": scripts += 1
                case "nav", "aside": chrome = true
                case "meta":
                    let property = (child.attribute("property") ?? child.attribute("name") ?? "").lowercased()
                    if property.hasPrefix("og:") || property.hasPrefix("twitter:") { social = true }
                default: break
                }
                scan(child)
            }
        }
        scan(document)
        return scripts >= 2 || chrome || social
    }
}

extension Block {
    var isReadableText: Bool {
        switch self {
        case .paragraph(let t), .heading(let t, _): !t.isBlank
        default: false
        }
    }
}
