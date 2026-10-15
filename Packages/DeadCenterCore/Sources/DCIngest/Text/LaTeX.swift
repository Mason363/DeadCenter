import Foundation

/// Finds TeX math in running text and replaces it with readable Unicode.
enum LaTeX {
    static let mathEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "alignat", "alignat*", "gather", "gather*", "multline",
        "multline*", "eqnarray", "eqnarray*", "displaymath", "math", "flalign", "flalign*", "aligned", "gathered",
        "split", "cases", "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "dmath",
        "array", "subequations",
    ]

    /// Renders TeX math source as Unicode text.
    static func renderMath(_ tex: String) -> String {
        MathRenderer.render(tex)
    }

    /// Replaces `$…$`, `$$…$$`, `\(…\)`, `\[…\]`, and math environments in `text`.
    ///
    /// Inline `$` follows Pandoc's rule (no space just inside the delimiters, no digit right after
    /// the closing one), so prices like "$5 and $10" stay as they are.
    /// - Parameter markdownSafe: escape the rendered math so a Markdown parser leaves it alone.
    static func convertingMath(in text: String, markdownSafe: Bool = false) -> String {
        guard text.contains("$") || text.contains("\\") else { return text }
        let chars = Array(text)
        var out = ""
        var i = 0
        func emit(_ math: String) {
            let rendered = renderMath(math)
            out += markdownSafe ? markdownEscaped(rendered) : rendered
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "$" {
                    out += markdownSafe ? "\\$" : "$"
                    i += 2
                    continue
                }
                if next == "(" || next == "[", let end = find(next == "(" ? "\\)" : "\\]", in: chars, from: i + 2) {
                    let body = String(chars[(i + 2)..<end])
                    if looksLikeMath(body) {
                        emit(body)
                        i = end + 2
                        continue
                    }
                }
                if let end = environmentEnd(in: chars, at: i) {
                    emit(String(chars[i..<end]))
                    i = end
                    continue
                }
                out.append(c)
                i += 1
                continue
            }
            if c == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$", let end = find("$$", in: chars, from: i + 2) {
                    emit(String(chars[(i + 2)..<end]))
                    i = end + 2
                    continue
                }
                if let end = inlineDollarEnd(chars, from: i) {
                    let body = String(chars[(i + 1)..<end])
                    if looksLikeMath(body) {
                        emit(body)
                        i = end + 1
                        continue
                    }
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Whether a delimited span is formula rather than prose in brackets.
    static func looksLikeMath(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count <= 3 { return true }
        return trimmed.contains { "\\^_=+<>{}|/*".contains($0) || $0.isNumber }
    }

    /// Backslash-escapes ASCII punctuation so CommonMark treats it literally.
    static func markdownEscaped(_ text: String) -> String {
        var out = ""
        for ch in text {
            if ch.isASCII, ch.isPunctuation || ch.isSymbol { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func find(_ pattern: String, in chars: [Character], from start: Int) -> Int? {
        let p = Array(pattern)
        var k = start
        while k + p.count <= chars.count {
            if chars[k] == p[0], chars[k..<(k + p.count)].elementsEqual(p), k == 0 || chars[k - 1] != "\\" || pattern.hasPrefix("\\") {
                return k
            }
            k += 1
        }
        return nil
    }

    /// The closing `$` of an inline formula opening at `start`, by Pandoc's rules.
    private static func inlineDollarEnd(_ chars: [Character], from start: Int) -> Int? {
        guard start + 1 < chars.count, !chars[start + 1].isWhitespace, chars[start + 1] != "$" else { return nil }
        var k = start + 1
        while k < chars.count, k - start < 400 {
            let c = chars[k]
            if c == "\n", k + 1 < chars.count, chars[k + 1] == "\n" { return nil }
            if c == "\\" { k += 2; continue }
            if c == "$" {
                let afterIsDigit = k + 1 < chars.count && chars[k + 1].isNumber
                if !chars[k - 1].isWhitespace, !afterIsDigit { return k }
                return nil
            }
            k += 1
        }
        return nil
    }

    /// The end of a `\begin{env}…\end{env}` math environment starting at `start`.
    private static func environmentEnd(in chars: [Character], at start: Int) -> Int? {
        let begin = Array("\\begin{")
        guard start + begin.count < chars.count, chars[start..<(start + begin.count)].elementsEqual(begin) else { return nil }
        var k = start + begin.count
        var name = ""
        while k < chars.count, chars[k] != "}", name.count < 20 { name.append(chars[k]); k += 1 }
        guard mathEnvironments.contains(name) else { return nil }
        let close = Array("\\end{\(name)}")
        guard let end = find(String(close), in: chars, from: k) else { return nil }
        return end + close.count
    }
}

/// Text-mode LaTeX: accents, quotes, dashes, and formatting commands, with math rendered.
enum LaTeXText {
    /// Converts a run of LaTeX prose (no structure) to plain text.
    static func inline(_ source: String) -> String {
        let withMath = LaTeX.convertingMath(in: source)
        let chars = Array(withMath)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                i = command(in: chars, at: i, into: &out)
            case "{", "}":
                i += 1
            case "~":
                out.append(" ")
                i += 1
            case "`":
                if i + 1 < chars.count, chars[i + 1] == "`" { out.append("“"); i += 2 } else { out.append("‘"); i += 1 }
            case "'":
                if i + 1 < chars.count, chars[i + 1] == "'" { out.append("”"); i += 2 } else { out.append("’"); i += 1 }
            case "-":
                if i + 2 < chars.count, chars[i + 1] == "-", chars[i + 2] == "-" { out.append("—"); i += 3 }
                else if i + 1 < chars.count, chars[i + 1] == "-" { out.append("–"); i += 2 }
                else { out.append("-"); i += 1 }
            default:
                out.append(c)
                i += 1
            }
        }
        return out
    }

    private static let accents: [Character: String] = [
        "'": "\u{301}", "`": "\u{300}", "^": "\u{302}", "\"": "\u{308}", "~": "\u{303}", "=": "\u{304}", ".": "\u{307}",
        "c": "\u{327}", "v": "\u{30C}", "u": "\u{306}", "H": "\u{30B}", "k": "\u{328}", "r": "\u{30A}",
    ]

    private static let letters = MathSymbols.table([
        ("ss", "ß"), ("o", "ø"), ("O", "Ø"), ("aa", "å"), ("AA", "Å"), ("ae", "æ"), ("AE", "Æ"), ("oe", "œ"),
        ("OE", "Œ"), ("l", "ł"), ("L", "Ł"), ("i", "ı"), ("ldots", "…"), ("dots", "…"), ("textellipsis", "…"),
        ("LaTeX", "LaTeX"), ("TeX", "TeX"), ("LaTeXe", "LaTeX2e"), ("textendash", "–"), ("textemdash", "—"),
        ("textbullet", "•"), ("textdegree", "°"), ("copyright", "©"), ("textregistered", "®"), ("texttrademark", "™"),
        ("S", "§"), ("P", "¶"), ("dag", "†"), ("ddag", "‡"), ("pounds", "£"), ("euro", "€"), ("textasciitilde", "~"),
        ("textbackslash", "\\"), ("textbar", "|"), ("textless", "<"), ("textgreater", ">"), ("slash", "/"),
    ])

    /// Commands whose (last) argument is not read: references, labels, citations, layout.
    private static let dropped: Set<String> = [
        "label", "ref", "eqref", "autoref", "cref", "Cref", "pageref", "cite", "citep", "citet", "citealp",
        "citeauthor", "citeyear", "nocite", "footnote", "footnotemark", "footnotetext", "index", "hspace", "vspace",
        "includegraphics", "bibliographystyle", "bibliography", "usepackage", "documentclass", "input", "include",
        "thanks", "pagestyle", "thispagestyle", "setlength", "addtolength", "setcounter", "newcommand",
        "renewcommand", "providecommand", "newenvironment", "color", "phantom", "caption", "todo",
    ]

    private static func command(in chars: [Character], at start: Int, into out: inout String) -> Int {
        var i = start + 1
        guard i < chars.count else { return i }
        let first = chars[i]
        if let mark = accents[first], !first.isLetter || (i + 1 < chars.count && (chars[i + 1] == "{" || !chars[i + 1].isLetter)) {
            // \'e, \'{e}, \c{c}
            i += 1
            var base = ""
            if i < chars.count, chars[i] == "{" {
                i += 1
                while i < chars.count, chars[i] != "}" { base.append(chars[i]); i += 1 }
                i += 1
            } else if i < chars.count, chars[i] != " " {
                base = String(chars[i])
                i += 1
            }
            out += (base + mark).precomposedStringWithCanonicalMapping
            return i
        }
        guard first.isLetter else {
            // \%, \&, \$, \#, \_, \{, \}, "\\" (line break), "\ " (space)
            switch first {
            case "\\", " ", ",", ";", ":", "!": out.append(" ")
            default: out.append(first)
            }
            return i + 1
        }
        var name = ""
        while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
        if i < chars.count, chars[i] == "*" { i += 1 }
        if let letter = letters[name] {
            out += letter
            // A control word swallows the space after it, as in TeX; "{}" ends it explicitly.
            if i + 1 < chars.count, chars[i] == "{", chars[i + 1] == "}" { i += 2 }
            else if i < chars.count, chars[i] == " " { i += 1 }
            return i
        }
        if dropped.contains(name) {
            i = skipArguments(chars, from: i, groups: name == "newcommand" || name == "renewcommand" ? 2 : 1)
            return i
        }
        switch name {
        case "href":
            i = skipArguments(chars, from: i, groups: 1)
        case "url", "path":
            return i
        case "item":
            // A list label in brackets reads as its text.
            if i < chars.count, chars[i] == "[" {
                i += 1
                var label = ""
                while i < chars.count, chars[i] != "]" { label.append(chars[i]); i += 1 }
                out += inline(label) + " "
                return i + 1
            }
            if i < chars.count, chars[i] == " " { i += 1 }
        case "textcolor":
            i = skipArguments(chars, from: i, groups: 1)
        default:
            if i < chars.count, chars[i] == " " { i += 1 }
        }
        // Formatting and unknown commands: the command goes, its argument stays as plain content.
        return i
    }

    /// Skips optional `[…]` arguments and `groups` brace groups.
    private static func skipArguments(_ chars: [Character], from start: Int, groups: Int) -> Int {
        var i = start
        var remaining = groups
        while i < chars.count {
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count else { break }
            if chars[i] == "[" {
                while i < chars.count, chars[i] != "]" { i += 1 }
                i += 1
                continue
            }
            guard chars[i] == "{", remaining > 0 else { break }
            var level = 0
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == "{" { level += 1 }
                if chars[i] == "}" { level -= 1; if level == 0 { i += 1; break } }
                i += 1
            }
            remaining -= 1
        }
        return min(i, chars.count)
    }
}
