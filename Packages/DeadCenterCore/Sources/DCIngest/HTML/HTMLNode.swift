import Foundation

/// A minimal DOM produced by `HTMLParser`.
enum HTMLNode {
    case element(HTMLElement)
    case text(String)
}

final class HTMLElement {
    /// Lowercased qualified name, such as "p" or "epub:switch". The root is "#document".
    let name: String
    /// Lowercased attribute names with decoded values, in source order.
    var attributes: [(name: String, value: String)]
    var children: [HTMLNode] = []

    init(name: String, attributes: [(name: String, value: String)] = []) {
        self.name = name
        self.attributes = attributes
    }

    /// The name without a namespace prefix.
    var localName: Substring {
        guard let colon = name.lastIndex(of: ":") else { return Substring(name) }
        return name[name.index(after: colon)...]
    }

    func attribute(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    /// The value of an attribute matched by local name, so "epub:type" also matches "type" in any namespace.
    func attribute(localName: String) -> String? {
        attributes.first { $0.name == localName || $0.name.hasSuffix(":" + localName) }?.value
    }

    var elementChildren: [HTMLElement] {
        children.compactMap { if case .element(let e) = $0 { e } else { nil } }
    }

    /// Concatenated descendant text.
    var textContent: String {
        var out = ""
        appendText(to: &out)
        return out
    }

    private func appendText(to out: inout String) {
        for child in children {
            switch child {
            case .text(let t): out += t
            case .element(let e): e.appendText(to: &out)
            }
        }
    }

    /// Depth-first search over descendants (not including self).
    func first(where predicate: (HTMLElement) -> Bool) -> HTMLElement? {
        for child in elementChildren {
            if predicate(child) { return child }
            if let found = child.first(where: predicate) { return found }
        }
        return nil
    }

    func all(where predicate: (HTMLElement) -> Bool) -> [HTMLElement] {
        var out: [HTMLElement] = []
        collect(where: predicate, into: &out)
        return out
    }

    private func collect(where predicate: (HTMLElement) -> Bool, into out: inout [HTMLElement]) {
        for child in elementChildren {
            if predicate(child) { out.append(child) }
            child.collect(where: predicate, into: &out)
        }
    }

    func appendText(_ text: String) {
        if case .text(let existing)? = children.last {
            children[children.count - 1] = .text(existing + text)
        } else {
            children.append(.text(text))
        }
    }
}

extension HTMLElement {
    /// The document `<title>`, ignoring titles inside SVG.
    var documentTitle: String? {
        var found: HTMLElement?
        func search(_ element: HTMLElement) {
            for child in element.elementChildren where found == nil {
                if child.localName == "svg" { continue }
                if child.localName == "title" { found = child; return }
                if child.localName != "body" { search(child) }
            }
        }
        search(self)
        let title = found.map { TextNormalizer.clean($0.textContent) }
        return title?.isEmpty == false ? title : nil
    }

    /// Serializes the document as well-formed markup, the input JSDOMParser requires.
    func wellFormedDocument() -> String {
        let html = first { $0.localName == "html" }
        let head = (html ?? self).first { $0.localName == "head" }
        let body = (html ?? self).first { $0.localName == "body" }

        var out = "<html><head>"
        if let head {
            for child in head.elementChildren where ["title", "meta", "base", "script"].contains(String(child.localName)) {
                if child.localName == "script", child.attribute("type")?.lowercased() != "application/ld+json" { continue }
                child.serialize(into: &out)
            }
        } else if let title = documentTitle {
            out += "<title>" + Self.escape(title, quote: false) + "</title>"
        }
        out += "</head><body>"
        if let body {
            for child in body.children { Self.serialize(child, into: &out) }
        } else {
            for child in (html ?? self).children {
                if case .element(let e) = child, e.localName == "head" { continue }
                Self.serialize(child, into: &out)
            }
        }
        out += "</body></html>"
        return out
    }

    private static func serialize(_ node: HTMLNode, into out: inout String) {
        switch node {
        case .text(let t): out += escape(t, quote: false)
        case .element(let e): e.serialize(into: &out)
        }
    }

    private func serialize(into out: inout String) {
        let local = String(localName)
        if HTMLParser.droppedFromSerialization.contains(local) { return }
        if local == "script" {
            let type = attribute("type")?.lowercased() ?? ""
            if type.hasPrefix("math/tex") {
                // Readability drops scripts; keep MathJax's TeX source as a marked span.
                out += "<span class=\"\(Self.texClass)\">" + Self.escape(textContent, quote: false) + "</span>"
                return
            }
            if type != "application/ld+json" { return }
        }
        // JSDOMParser only knows unprefixed names. Legacy presentational tags aren't "phrasing
        // content" to Readability, which then splits paragraphs around them; spans are.
        let name = Self.serializedNames[local] ?? local
        out += "<" + name
        for attr in attributes where Self.isSerializableAttributeName(attr.name) {
            out += " " + attr.name + "=\"" + Self.escape(attr.value, quote: true) + "\""
        }
        if HTMLParser.voidElements.contains(local) {
            out += "/>"
            return
        }
        out += ">"
        for child in children { Self.serialize(child, into: &out) }
        out += "</" + name + ">"
    }

    private static let serializedNames: [String: String] = [
        "font": "span", "big": "span", "tt": "span", "strike": "span", "s": "span", "u": "span", "nobr": "span",
        "blink": "span", "center": "div",
    ]

    private static func isSerializableAttributeName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "."
        }
    }

    /// Class of the span that carries TeX source through Readability.
    static let texClass = "dc-tex"

    static func escape(_ text: String, quote: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where quote: out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
