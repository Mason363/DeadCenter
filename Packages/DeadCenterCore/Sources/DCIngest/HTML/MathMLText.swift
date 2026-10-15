import Foundation

/// Readable text for MathML (`<math>`), as produced by KaTeX, MathJax, and EPUB 3 books.
enum MathMLText {
    static func text(of math: HTMLElement) -> String {
        // KaTeX and MathJax keep the TeX source as an annotation; it renders best.
        if let annotation = math.first(where: {
            $0.localName == "annotation" && ($0.attribute("encoding") ?? "").lowercased().contains("tex")
        }) {
            return LaTeX.renderMath(annotation.textContent)
        }
        if let alt = math.attribute("alttext"), !alt.isBlank {
            return LaTeX.renderMath(alt)
        }
        return tidy(linearize(math))
    }

    private static func linearize(_ element: HTMLElement) -> String {
        let children = element.elementChildren
        func child(_ index: Int) -> String { index < children.count ? linearize(children[index]) : "" }

        switch element.localName {
        case "annotation", "annotation-xml", "none", "mprescripts":
            return ""
        case "semantics":
            return child(0)
        case "mi", "mn", "mtext", "ms":
            return element.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        case "mo":
            let op = element.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return spacedOperators.contains(op) ? " \(op) " : op
        case "mspace":
            return " "
        case "msup":
            return child(0) + MathRenderer.script(child(1), superscript: true)
        case "msub":
            return child(0) + MathRenderer.script(child(1), superscript: false)
        case "msubsup":
            return child(0) + MathRenderer.script(child(1), superscript: false) + MathRenderer.script(child(2), superscript: true)
        case "munder":
            return child(0) + MathRenderer.script(child(1), superscript: false)
        case "mover":
            let accent = child(1)
            return ["^", "ˆ", "‾", "¯", "~", "˜", "→", "⃗", "˙", "¨"].contains(accent) ? child(0) : child(0) + MathRenderer.script(accent, superscript: true)
        case "munderover":
            return child(0) + MathRenderer.script(child(1), superscript: false) + MathRenderer.script(child(2), superscript: true)
        case "mfrac":
            return MathRenderer.fraction(tidy(child(0)), tidy(child(1)))
        case "msqrt":
            return "√" + MathRenderer.wrapped(tidy(children.map(linearize).joined()))
        case "mroot":
            return MathRenderer.script(child(1), superscript: true) + "√" + MathRenderer.wrapped(tidy(child(0)))
        case "mtable":
            return children.map { tidy(linearize($0)) }.filter { !$0.isEmpty }.joined(separator: "; ")
        case "mtr", "mlabeledtr":
            return children.map { tidy(linearize($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
        default:
            var out = ""
            for node in element.children {
                switch node {
                case .text(let t): out += t
                case .element(let e): out += linearize(e)
                }
            }
            return out
        }
    }

    private static let spacedOperators: Set<String> = [
        "=", "+", "−", "-", "±", "×", "·", "÷", "<", ">", "≤", "≥", "≠", "≈", "≡", "→", "⇒", "⇔", "∈", "∉", "⊂", "⊆", "∪", "∩",
    ]

    private static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
