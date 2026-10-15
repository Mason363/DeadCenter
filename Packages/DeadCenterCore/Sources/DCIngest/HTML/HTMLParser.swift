import Foundation

/// A small, forgiving HTML/XHTML parser.
///
/// Foundation's `XMLDocument(…, .documentTidyHTML)` predates HTML5: it silently drops `nav`,
/// `footer`, `figure`, `picture`, `section`, `svg`… while keeping their text, which leaks page
/// chrome and loses figure captions. This parser keeps every element, applies the HTML rules
/// that matter for reading (void elements, implied end tags, raw-text elements, character
/// references), and never fails. In XML mode it skips the HTML-specific rules so it can read
/// EPUB package files and DOCX parts tolerantly too.
struct HTMLParser {
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track",
        "wbr", "keygen", "command", "basefont", "bgsound", "frame", "image",
    ]

    /// Elements whose content is never needed, so it isn't kept (or serialized).
    static let droppedFromSerialization: Set<String> = ["style", "noembed", "noframes", "xmp", "iframe", "template"]

    private static let rawTextElements: Set<String> = ["script", "style", "xmp", "iframe", "noembed", "noframes", "template"]
    private static let escapableRawTextElements: Set<String> = ["title", "textarea"]

    /// Start tags that implicitly close an open `<p>`.
    private static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr",
        "li", "dd", "dt", "listing", "main", "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "ul",
    ]
    private static let paragraphScopeBoundaries: Set<String> = [
        "button", "table", "td", "th", "caption", "html", "marquee", "object", "applet", "template",
    ]
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private static let headElements: Set<String> = ["title", "meta", "link", "style", "script", "base", "noscript", "template", "head"]
    private static let maxDepth = 200

    private let bytes: [UInt8]
    private let xmlMode: Bool
    private var index = 0
    private var stack: [HTMLElement] = []
    private let root = HTMLElement(name: "#document")

    /// Parses `html` into a tree rooted at a "#document" element.
    static func parse(_ html: String, xmlMode: Bool = false) -> HTMLElement {
        var parser = HTMLParser(bytes: Array(html.utf8), xmlMode: xmlMode)
        parser.run()
        return parser.root
    }

    private init(bytes: [UInt8], xmlMode: Bool) {
        self.bytes = bytes
        self.xmlMode = xmlMode
        self.stack = [root]
    }

    private var current: HTMLElement { stack[stack.count - 1] }

    // MARK: - Tokenizing

    private mutating func run() {
        let n = bytes.count
        while index < n {
            if bytes[index] == UInt8(ascii: "<"), index + 1 < n {
                let next = bytes[index + 1]
                if next == UInt8(ascii: "!") {
                    markupDeclaration()
                } else if next == UInt8(ascii: "?") {
                    skip(past: UInt8(ascii: ">"))
                } else if next == UInt8(ascii: "/") {
                    endTag()
                } else if isASCIILetter(next) {
                    startTag()
                } else {
                    appendText(from: index, to: index + 1)
                    index += 1
                }
            } else {
                let start = index
                index += 1
                while index < n, bytes[index] != UInt8(ascii: "<") { index += 1 }
                appendText(from: start, to: index)
            }
        }
    }

    private mutating func markupDeclaration() {
        if hasPrefix("<!--") {
            if let end = find("-->", from: index + 4) { index = end + 3 } else { index = bytes.count }
        } else if hasPrefix("<![CDATA[") {
            let start = index + 9
            let end = find("]]>", from: start) ?? bytes.count
            if end > start { current.appendText(String(decoding: bytes[start..<end], as: UTF8.self)) }
            index = min(end + 3, bytes.count)
        } else {
            skip(past: UInt8(ascii: ">"))
        }
    }

    private mutating func endTag() {
        index += 2
        let name = readName()
        skip(past: UInt8(ascii: ">"))
        guard !name.isEmpty else { return }
        handleEndTag(name)
    }

    private mutating func startTag() {
        index += 1
        let name = readName()
        var attributes: [(name: String, value: String)] = []
        var selfClosing = false
        let n = bytes.count
        while index < n {
            skipWhitespace()
            guard index < n else { break }
            let c = bytes[index]
            if c == UInt8(ascii: ">") { index += 1; break }
            if c == UInt8(ascii: "/") {
                index += 1
                if index < n, bytes[index] == UInt8(ascii: ">") { selfClosing = true; index += 1; break }
                continue
            }
            let attrStart = index
            while index < n, !isWhitespace(bytes[index]), bytes[index] != UInt8(ascii: "="),
                  bytes[index] != UInt8(ascii: ">"), !(bytes[index] == UInt8(ascii: "/") && index + 1 < n && bytes[index + 1] == UInt8(ascii: ">")) {
                index += 1
            }
            let attrName = String(decoding: bytes[attrStart..<index], as: UTF8.self).lowercased()
            if index == attrStart { index += 1; continue }
            skipWhitespace()
            var value = ""
            if index < n, bytes[index] == UInt8(ascii: "=") {
                index += 1
                skipWhitespace()
                value = readAttributeValue()
            }
            if !attributes.contains(where: { $0.name == attrName }) {
                attributes.append((attrName, value))
            }
        }
        guard !name.isEmpty else { return }
        handleStartTag(name, attributes: attributes, selfClosing: selfClosing)
    }

    private mutating func readName() -> String {
        let start = index
        let n = bytes.count
        while index < n {
            let c = bytes[index]
            if isWhitespace(c) || c == UInt8(ascii: ">") || c == UInt8(ascii: "/") { break }
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self).lowercased()
    }

    private mutating func readAttributeValue() -> String {
        let n = bytes.count
        guard index < n else { return "" }
        let quote = bytes[index]
        let start: Int
        if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
            index += 1
            start = index
            while index < n, bytes[index] != quote { index += 1 }
            let raw = String(decoding: bytes[start..<index], as: UTF8.self)
            if index < n { index += 1 }
            return HTMLEntities.decode(raw, inAttribute: true)
        }
        start = index
        while index < n, !isWhitespace(bytes[index]), bytes[index] != UInt8(ascii: ">") { index += 1 }
        return HTMLEntities.decode(String(decoding: bytes[start..<index], as: UTF8.self), inAttribute: true)
    }

    private mutating func appendText(from start: Int, to end: Int) {
        guard end > start else { return }
        let raw = String(decoding: bytes[start..<end], as: UTF8.self)
        current.appendText(HTMLEntities.decode(raw))
    }

    // MARK: - Tree building

    private mutating func handleStartTag(_ name: String, attributes: [(name: String, value: String)], selfClosing: Bool) {
        let local = Self.localName(name)
        if !xmlMode { applyImpliedEndTags(before: local) }
        if !xmlMode, ["html", "head", "body"].contains(local), stack.contains(where: { $0.name == name }) {
            return
        }
        let element = HTMLElement(name: name, attributes: attributes)
        current.children.append(.element(element))

        if selfClosing || (!xmlMode && Self.voidElements.contains(local)) { return }
        if !xmlMode, Self.rawTextElements.contains(local) || Self.escapableRawTextElements.contains(local) {
            let isEscapable = Self.escapableRawTextElements.contains(local)
            let type = element.attribute("type")?.lowercased() ?? ""
            let isStructuredData = local == "script" && (type.contains("ld+json") || type.hasPrefix("math/tex"))
            readRawText(into: element, keep: isEscapable || isStructuredData, decode: isEscapable)
            return
        }
        if stack.count < Self.maxDepth { stack.append(element) }
    }

    private mutating func handleEndTag(_ name: String) {
        let local = Self.localName(name)
        if !xmlMode {
            if local == "br" {
                // `<br></br>` in XHTML is one break; a stray `</br>` elsewhere acts like `<br>`.
                if case .element(let last)? = current.children.last, last.name == "br" { return }
                handleStartTag("br", attributes: [], selfClosing: true)
                return
            }
            // Content may follow `</body>` or `</html>`; keep them open.
            if local == "html" || local == "body" { return }
        }
        guard let i = stack.lastIndex(where: { $0.name == name }), i > 0 else { return }
        stack.removeSubrange(i...)
    }

    private mutating func applyImpliedEndTags(before local: String) {
        // Anything but metadata ends an unclosed <head>.
        if !Self.headElements.contains(local), let i = stack.lastIndex(where: { $0.localName == "head" }) {
            stack.removeSubrange(i...)
        }
        if Self.closesParagraph.contains(local) {
            close("p", stoppingAt: Self.paragraphScopeBoundaries)
        }
        switch local {
        case "li":
            close("li", stoppingAt: ["ul", "ol", "menu", "table", "td", "th"])
        case "dd", "dt":
            close(["dd", "dt"], stoppingAt: ["dl", "table", "td", "th"])
        case "tr":
            close("tr", stoppingAt: ["table", "thead", "tbody", "tfoot"])
        case "td", "th":
            close(["td", "th"], stoppingAt: ["tr", "table"])
        case "thead", "tbody", "tfoot":
            close(["thead", "tbody", "tfoot"], stoppingAt: ["table"])
        case "option", "optgroup":
            close(["option"], stoppingAt: ["select", "datalist"])
        case "a":
            close("a", stoppingAt: ["table", "td", "th", "button"])
        case "rt", "rp":
            close(["rt", "rp"], stoppingAt: ["ruby"])
        default:
            if Self.headings.contains(local), let top = stack.last, Self.headings.contains(String(top.localName)) {
                stack.removeLast()
            }
        }
    }

    private mutating func close(_ name: String, stoppingAt boundaries: Set<String>) {
        close([name], stoppingAt: boundaries)
    }

    private mutating func close(_ names: Set<String>, stoppingAt boundaries: Set<String>) {
        var i = stack.count - 1
        while i > 0 {
            let local = String(stack[i].localName)
            if names.contains(local) {
                stack.removeSubrange(i...)
                return
            }
            if boundaries.contains(local) { return }
            i -= 1
        }
    }

    /// Consumes content up to the matching end tag without interpreting markup.
    private mutating func readRawText(into element: HTMLElement, keep: Bool, decode: Bool) {
        let start = index
        let closing = Array("</\(element.localName)".utf8)
        var end = bytes.count
        var i = index
        while i + closing.count <= bytes.count {
            if bytes[i] == UInt8(ascii: "<"), matchesIgnoringCase(closing, at: i) {
                let after = i + closing.count
                if after >= bytes.count || isWhitespace(bytes[after]) || bytes[after] == UInt8(ascii: ">") || bytes[after] == UInt8(ascii: "/") {
                    end = i
                    break
                }
            }
            i += 1
        }
        if keep, end > start {
            let raw = String(decoding: bytes[start..<end], as: UTF8.self)
            element.appendText(decode ? HTMLEntities.decode(raw) : raw)
        }
        index = end
        if end < bytes.count { skip(past: UInt8(ascii: ">")) }
    }

    // MARK: - Byte helpers

    private static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    private func isASCIILetter(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
    }

    private mutating func skip(past byte: UInt8) {
        while index < bytes.count, bytes[index] != byte { index += 1 }
        index = min(index + 1, bytes.count)
    }

    private func hasPrefix(_ s: String) -> Bool {
        matchesIgnoringCase(Array(s.utf8), at: index)
    }

    private func matchesIgnoringCase(_ pattern: [UInt8], at position: Int) -> Bool {
        guard position + pattern.count <= bytes.count else { return false }
        for (k, p) in pattern.enumerated() {
            var b = bytes[position + k]
            if b >= 0x41 && b <= 0x5A { b += 0x20 }
            var q = p
            if q >= 0x41 && q <= 0x5A { q += 0x20 }
            if b != q { return false }
        }
        return true
    }

    private func find(_ s: String, from start: Int) -> Int? {
        let pattern = Array(s.utf8)
        guard !pattern.isEmpty, start < bytes.count else { return nil }
        var i = start
        while i + pattern.count <= bytes.count {
            if bytes[i] == pattern[0], bytes[i..<(i + pattern.count)].elementsEqual(pattern) { return i }
            i += 1
        }
        return nil
    }
}
