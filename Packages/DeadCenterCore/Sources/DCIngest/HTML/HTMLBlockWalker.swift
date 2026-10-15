import Foundation
import DCModel

/// Walks an `HTMLParser` tree and produces blocks in reading order.
///
/// Shared by HTML files and strings, web archives, fetched web pages, EPUB chapters, and
/// HTML embedded in Markdown. Block elements become paragraphs and headings, images become
/// image blocks (with figure captions), and inline markup never breaks a paragraph.
final class HTMLBlockWalker {
    struct Options {
        var resolver: any ImageResolver
        /// Also skip elements whose role, class, or id marks them as navigation, ads, comments…
        /// Used when a full page is walked without Readability.
        var skipsPageChrome = false
        /// Chapter titles to insert where the element with a given id (or name) begins.
        var anchors: [String: [String]] = [:]
        /// Image sources already shown (such as an EPUB cover); repeats are skipped.
        var seenImages: Set<ImageAsset.Source> = []
    }

    private var options: Options
    private var blocks: [Block] = []
    private var inline = ""
    private var deferredImages: [ImageAsset] = []
    /// Break marker for `<br>`: a control character that never survives cleaning.
    private static let lineBreak: Character = "\u{1}"

    init(options: Options) {
        self.options = options
    }

    /// Image sources emitted so far, including those passed in.
    var seenImages: Set<ImageAsset.Source> { options.seenImages }

    /// Anchor ids that were never reached (they sit inside skipped content).
    var unusedAnchors: Set<String> { Set(options.anchors.keys) }

    func walk(_ root: HTMLElement) -> [Block] {
        blocks = []
        visitChildren(of: root)
        flushParagraph()
        return blocks
    }

    // MARK: - Traversal

    private func visitChildren(of element: HTMLElement) {
        for child in element.children {
            switch child {
            case .text(let text): inline += text
            case .element(let e): visit(e)
            }
        }
    }

    private func visit(_ e: HTMLElement) {
        let name = String(e.localName)
        insertAnchoredChapters(for: e)
        if let tex = Self.texSource(of: e, name: name) {
            inline += LaTeX.renderMath(tex)
            return
        }
        if Self.skippedElements.contains(name) || isHidden(e) || isNoteReference(e, name: name) { return }
        if options.skipsPageChrome, isPageChrome(e, name: name) { return }

        switch name {
        case "br":
            inline.append(Self.lineBreak)
        case "wbr":
            break
        case "h1", "h2", "h3", "h4", "h5", "h6":
            flushParagraph()
            visitChildren(of: e)
            let text = takeInline()
            if !text.isEmpty { blocks.append(.heading(text, level: Int(String(name.last!)) ?? 2)) }
            emitDeferredImages()
        case "img", "image":
            handleImage(e, caption: nil)
        case "picture":
            handlePicture(e, caption: nil)
        case "figure":
            handleFigure(e)
        case "pre", "listing", "plaintext":
            flushParagraph()
            let text = e.textContent
            if !CodeDetector.looksLikeCode(text) {
                blocks.append(contentsOf: PlainTextParagraphs.split(text).map(Block.paragraph))
            }
        case "math":
            inline += MathMLText.text(of: e)
        default:
            if Self.blockElements.contains(name) {
                if Self.listContainers.contains(name), isLinkList(e) { return }
                flushParagraph()
                visitChildren(of: e)
                flushParagraph()
            } else {
                visitChildren(of: e)
            }
        }
    }

    private func insertAnchoredChapters(for e: HTMLElement) {
        guard !options.anchors.isEmpty else { return }
        for key in [e.attribute("id"), e.attribute("name")].compactMap({ $0 }) {
            guard let titles = options.anchors.removeValue(forKey: key) else { continue }
            flushParagraph()
            blocks.append(contentsOf: titles.map(Block.chapter))
        }
    }

    // MARK: - Paragraphs

    private func takeInline() -> String {
        defer { inline = "" }
        return LaTeX.convertingMath(in: TextNormalizer.clean(inline.replacingOccurrences(of: String(Self.lineBreak), with: " ")))
    }

    /// TeX source of a MathJax 2 `<script type="math/tex">` (or the span it becomes for Readability).
    private static func texSource(of e: HTMLElement, name: String) -> String? {
        switch name {
        case "script" where e.attribute("type")?.lowercased().hasPrefix("math/tex") == true:
            return e.textContent
        case "span" where e.attribute("class") == HTMLElement.texClass:
            return e.textContent
        default:
            return nil
        }
    }

    private func flushParagraph() {
        if !inline.isEmpty {
            for piece in splitOnDoubleBreaks(inline) {
                let cleaned = TextNormalizer.clean(piece.replacingOccurrences(of: String(Self.lineBreak), with: " "))
                let text = Self.removingEmptyBrackets(LaTeX.convertingMath(in: cleaned))
                if !text.isEmpty, !Self.isBareNoteMarker(text) { blocks.append(.paragraph(text)) }
            }
            inline = ""
        }
        emitDeferredImages()
    }

    private static let emptyBrackets = try! NSRegularExpression(pattern: #"\s*(\[\s*\]|\(\s*\))"#)

    /// Brackets left behind by skipped footnote markers: "in []." → "in.".
    private static func removingEmptyBrackets(_ text: String) -> String {
        guard text.contains("[]") || text.contains("()") || text.contains("[ ]") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return emptyBrackets.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// A paragraph that is only a note marker, such as "[1]".
    private static func isBareNoteMarker(_ text: String) -> Bool {
        guard text.count <= 6, text.first == "[" || text.first == "(", text.last == "]" || text.last == ")" else { return false }
        return text.dropFirst().dropLast().allSatisfy { $0.isNumber || $0 == "*" || $0 == "†" }
    }

    /// Two `<br>`s in a row (with only whitespace between) separate paragraphs.
    private func splitOnDoubleBreaks(_ text: String) -> [Substring] {
        guard text.contains(Self.lineBreak) else { return [Substring(text)] }
        var pieces: [Substring] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == Self.lineBreak {
                var j = text.index(after: i)
                while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
                if j < text.endIndex, text[j] == Self.lineBreak {
                    pieces.append(text[start..<i])
                    var k = text.index(after: j)
                    while k < text.endIndex, text[k] == Self.lineBreak || text[k].isWhitespace { k = text.index(after: k) }
                    start = k
                    i = k
                    continue
                }
            }
            i = text.index(after: i)
        }
        pieces.append(text[start...])
        return pieces
    }

    private func emitDeferredImages() {
        guard !deferredImages.isEmpty else { return }
        blocks.append(contentsOf: deferredImages.map(Block.image))
        deferredImages.removeAll()
    }

    // MARK: - Images

    private func handleFigure(_ figure: HTMLElement) {
        let images = figure.all { ["img", "picture", "image"].contains(String($0.localName)) && !$0.isInsidePicture(of: figure) }
        guard !images.isEmpty else {
            flushParagraph()
            visitChildren(of: figure)
            flushParagraph()
            return
        }
        let caption = figure.first { $0.localName == "figcaption" }.map { TextNormalizer.clean($0.textContent) }
        flushParagraph()
        for (i, image) in images.enumerated() {
            let imageCaption = i == 0 ? caption : nil
            if image.localName == "picture" { handlePicture(image, caption: imageCaption) } else { handleImage(image, caption: imageCaption) }
        }
        emitDeferredImages()
    }

    private func handlePicture(_ picture: HTMLElement, caption: String?) {
        let img = picture.first { $0.localName == "img" }
        let sources = picture.elementChildren.filter { $0.localName == "source" }
        let best = sources.compactMap { source -> (String, Double)? in
            guard let set = source.attribute("srcset") ?? source.attribute("data-srcset") else { return nil }
            return SrcSet.best(in: set)
        }.max { $0.1 < $1.1 }
        if let img {
            handleImage(img, caption: caption, preferredReference: best?.0)
        } else if let best {
            place(reference: best.0, element: picture, caption: caption)
        }
    }

    private func handleImage(_ img: HTMLElement, caption: String?, preferredReference: String? = nil) {
        if let alt = img.attribute("alt"), isEmoji(img, alt: alt) {
            inline += alt
            return
        }
        guard let reference = preferredReference ?? Self.reference(of: img) else { return }
        place(reference: reference, element: img, caption: caption)
    }

    private func place(reference: String, element: HTMLElement, caption: String?) {
        let declaredWidth = Self.dimension(element.attribute("width"))
        let declaredHeight = Self.dimension(element.attribute("height"))
        if let w = declaredWidth, w < ImageData.minimumSide { return }
        if let h = declaredHeight, h < ImageData.minimumSide { return }
        if Self.looksLikeTracker(reference) { return }
        guard let source = options.resolver.source(for: reference), !options.seenImages.contains(source) else { return }

        let text = caption ?? meaningfulAlt(element.attribute("alt")) ?? element.attribute("title").flatMap(meaningfulAlt)
        let asset: ImageAsset
        switch source {
        case .data(let data):
            guard let decoded = ImageData.asset(data, caption: text) else { return }
            asset = decoded
        case .url:
            asset = ImageAsset(source: source, pixelWidth: declaredWidth, pixelHeight: declaredHeight, caption: text)
        }
        options.seenImages.insert(source)
        if inline.isBlank {
            flushParagraph()
            blocks.append(.image(asset))
        } else {
            deferredImages.append(asset)
        }
    }

    private static func reference(of img: HTMLElement) -> String? {
        if let set = img.attribute("srcset") ?? img.attribute("data-srcset"), let best = SrcSet.best(in: set) {
            return best.0
        }
        let src = img.attribute("src") ?? img.attribute("xlink:href") ?? img.attribute("href")
        let lazy = ["data-src", "data-original", "data-lazy-src", "data-url", "data-hi-res-src"].lazy.compactMap { img.attribute($0) }.first
        if let src, !src.isEmpty, !isPlaceholder(src) { return src }
        return lazy ?? src
    }

    private static func isPlaceholder(_ src: String) -> Bool {
        let lower = src.lowercased()
        return (lower.hasPrefix("data:") && lower.count < 200) || lower.contains("blank.gif") || lower.contains("spacer.gif")
    }

    private static func looksLikeTracker(_ reference: String) -> Bool {
        let lower = reference.lowercased()
        guard !lower.hasPrefix("data:") else { return false }
        return ["/pixel", "pixel.gif", "/beacon", "tracking", "doubleclick.net", "/1x1", "spacer.gif", "facebook.com/tr", "/b/ss/", "scorecardresearch"]
            .contains { lower.contains($0) }
    }

    private static func dimension(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, !value.contains("%") else { return nil }
        return Int(digits)
    }

    private func meaningfulAlt(_ alt: String?) -> String? {
        guard let alt else { return nil }
        let text = TextNormalizer.clean(alt)
        let lower = text.lowercased()
        guard text.count >= 3,
              !["image", "photo", "picture", "img", "figure", "graphic", "untitled"].contains(lower),
              !(lower.range(of: #"^[\w\-]+\.(jpe?g|png|gif|webp|svg|tiff?|heic|bmp)$"#, options: .regularExpression) != nil)
        else { return nil }
        return text
    }

    private func isEmoji(_ img: HTMLElement, alt: String) -> Bool {
        if img.attribute("class")?.lowercased().contains("emoji") == true { return true }
        return alt.count == 1 && alt.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }

    // MARK: - Skipping

    private static let skippedElements: Set<String> = [
        "head", "script", "style", "noscript", "svg", "nav", "footer", "aside", "form", "button", "iframe",
        "template", "select", "option", "textarea", "input", "object", "embed", "canvas", "audio", "video", "map",
        "frameset", "frame", "link", "meta", "base", "param", "source", "track", "rp", "rt", "dialog", "title",
    ]

    private static let blockElements: Set<String> = [
        "address", "article", "blockquote", "body", "caption", "center", "dd", "details", "dir", "div", "dl", "dt",
        "fieldset", "figcaption", "header", "hgroup", "hr", "html", "legend", "li", "main", "menu", "ol", "p",
        "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul", "xmp",
    ]

    private func isHidden(_ e: HTMLElement) -> Bool {
        if e.attribute("hidden") != nil || e.attribute("aria-hidden") == "true" || e.attribute("type") == "hidden" { return true }
        if let style = e.attribute("style")?.lowercased().filter({ !$0.isWhitespace }),
           style.contains("display:none") || style.contains("visibility:hidden") {
            return true
        }
        if let cls = e.attribute("class")?.lowercased() {
            let tokens = cls.split(whereSeparator: \.isWhitespace)
            return tokens.contains { Self.hiddenClasses.contains(String($0)) }
        }
        return false
    }

    /// Footnote reference markers ("¹", "[12]") and EPUB page-break markers interrupt reading.
    private func isNoteReference(_ e: HTMLElement, name: String) -> Bool {
        let type = (e.attribute("epub:type") ?? "") + " " + (e.attribute("role") ?? "")
        if type.contains("noteref") || type.contains("pagebreak") || type.contains("doc-backlink") { return true }
        if name == "a" {
            // An in-page link whose text is just a number or symbol: "[<a href="#fn1">1</a>]".
            guard let href = e.attribute("href"), href.hasPrefix("#") else { return false }
            let text = e.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text.count <= 4 && text.allSatisfy { $0.isNumber || "[]()*†‡".contains($0) }
        }
        guard name == "sup" else { return false }
        let text = e.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        // Editorial markers such as "[citation needed]".
        if text.hasPrefix("["), text.hasSuffix("]"), text.count <= 30 { return true }
        guard !text.isEmpty, text.count <= 6 else { return false }
        let isMarker = text.allSatisfy { $0.isNumber || "[]()*†‡§¶,-ivx".contains($0) }
        let linksInternally = e.first { $0.localName == "a" && ($0.attribute("href")?.contains("#") ?? false) } != nil
            || e.attribute("class")?.contains("reference") == true || e.attribute("class")?.contains("footnote") == true
        return isMarker && linksInternally
    }

    private func isPageChrome(_ e: HTMLElement, name: String) -> Bool {
        guard !["body", "html", "main", "article"].contains(name) else { return false }
        if let role = e.attribute("role")?.lowercased(),
           ["navigation", "banner", "contentinfo", "complementary", "search", "menu", "menubar", "toolbar", "dialog", "alert", "alertdialog", "tablist"].contains(role) {
            return true
        }
        let identity = ((e.attribute("class") ?? "") + " " + (e.attribute("id") ?? "")).lowercased()
        guard !identity.isBlank else { return false }
        let words = identity.split { !$0.isLetter && !$0.isNumber }
        return words.contains { Self.chromeWords.contains(String($0)) }
    }

    private static let hiddenClasses: Set<String> = [
        "hidden", "sr-only", "visually-hidden", "visuallyhidden", "screen-reader-text", "pagenum", "page-number",
        "mw-editsection", "noprint", "reflist", "references", "mw-references-wrap", "navbox", "catlinks",
        // MathJax 2's rendered glyphs; the TeX source next to them is read instead.
        "mathjax", "mathjax_preview", "mathjax_display", "mathjax_svg", "mathjax_svg_display", "mathjax_chtml",
    ]

    private static let listContainers: Set<String> = ["ul", "ol", "dl", "table", "div", "section", "p"]

    /// A container that is mostly links (a table of contents, a "related" list, a menu), or a
    /// table in which nearly every row links somewhere (a contents table).
    private func isLinkList(_ e: HTMLElement) -> Bool {
        if e.localName == "table" {
            let rows = e.all { $0.localName == "tr" }
            let linkedRows = rows.filter { $0.first { $0.localName == "a" && $0.attribute("href") != nil } != nil }
            if rows.count >= 4, linkedRows.count * 5 >= rows.count * 4 { return true }
        }
        let links = e.all { $0.localName == "a" && $0.attribute("href") != nil }
        guard links.count >= 4 else { return false }
        let headings = e.all { ["h1", "h2", "h3", "h4", "h5", "h6"].contains(String($0.localName)) }
        let total = TextNormalizer.clean(e.textContent).count - headings.reduce(0) { $0 + TextNormalizer.clean($1.textContent).count }
        let linked = links.reduce(0) { $0 + TextNormalizer.clean($1.textContent).count }
        return total > 0 && Double(linked) >= Double(total) * 0.75
    }

    private static let chromeWords: Set<String> = [
        "nav", "navbar", "navigation", "menu", "sidebar", "footer", "comment", "comments", "share", "sharing",
        "social", "related", "advert", "advertisement", "ads", "ad", "promo", "newsletter", "subscribe", "cookie",
        "cookies", "consent", "breadcrumb", "breadcrumbs", "pagination", "popup", "modal", "masthead", "toolbar", "skip",
    ]
}

private extension HTMLElement {
    /// Whether this element sits inside a `<picture>` within `container` (handled with the picture).
    func isInsidePicture(of container: HTMLElement) -> Bool {
        guard localName == "img" else { return false }
        return container.first { $0.localName == "picture" && $0.first { $0 === self } != nil } != nil
    }
}

/// Picks the largest candidate in a `srcset`.
enum SrcSet {
    static func best(in srcset: String) -> (String, Double)? {
        var best: (String, Double)?
        var rest = Substring(srcset)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "," }
            guard !rest.isEmpty else { break }
            var url = rest.prefix { !$0.isWhitespace }
            rest = rest.dropFirst(url.count)
            var descriptor = Substring("")
            if url.hasSuffix(",") {
                while url.hasSuffix(",") { url = url.dropLast() }
            } else {
                descriptor = rest.prefix { $0 != "," }
                rest = rest.dropFirst(descriptor.count)
            }
            guard !url.isEmpty else { continue }
            let d = descriptor.trimmingCharacters(in: .whitespaces).lowercased()
            var score = 1000.0
            if d.hasSuffix("w"), let w = Double(d.dropLast()) { score = w }
            else if d.hasSuffix("x"), let x = Double(d.dropLast()) { score = x * 1000 }
            if score > (best?.1 ?? -1) { best = (String(url), score) }
        }
        return best
    }
}
