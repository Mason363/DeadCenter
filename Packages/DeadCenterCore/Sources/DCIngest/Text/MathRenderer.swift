import Foundation

/// Renders TeX math as plain Unicode text: x^2 → x², \frac{a}{b} → a/b, \alpha → α.
///
/// The source is parsed into atoms with TeX's spacing classes, so output spacing doesn't
/// depend on how the source was typed ("a\times b" and "a \times b" both give "a × b").
/// Formatting commands keep their argument; unknown commands are dropped.
struct MathRenderer {
    private struct Atom {
        var kind: MathSymbols.Kind
        var text: String
    }

    private let chars: [Character]
    private var i = 0
    private var depth: Int

    static func render(_ tex: String) -> String {
        render(tex, depth: 0)
    }

    private static func render(_ tex: String, depth: Int) -> String {
        guard depth < 32 else { return "" }
        var renderer = MathRenderer(chars: Array(tex), depth: depth)
        return join(renderer.atoms(until: nil))
    }

    private init(chars: [Character], depth: Int) {
        self.chars = chars
        self.depth = depth
    }

    // MARK: - Parsing

    private mutating func atoms(until terminator: Character?) -> [Atom] {
        var out: [Atom] = []
        while i < chars.count {
            let c = chars[i]
            if let terminator, c == terminator {
                i += 1
                return out
            }
            switch c {
            case "{":
                i += 1
                out += atoms(until: "}")
            case "}":
                i += 1
            case "^", "_":
                i += 1
                let argument = renderArgument()
                let script = Self.script(argument, superscript: c == "^")
                if let last = out.indices.last, out[last].kind != .space {
                    out[last].text += script
                } else {
                    out.append(Atom(kind: .ordinary, text: script))
                }
            case "\\":
                out += command()
            case "&", "~":
                i += 1
                out.append(Atom(kind: .space, text: " "))
            case "'":
                var primes = 0
                while i < chars.count, chars[i] == "'" { primes += 1; i += 1 }
                let mark = primes == 2 ? "″" : primes == 3 ? "‴" : String(repeating: "′", count: primes)
                if let last = out.indices.last { out[last].text += mark } else { out.append(Atom(kind: .ordinary, text: mark)) }
            case "$":
                i += 1
            default:
                i += 1
                if c.isWhitespace { continue }
                out.append(Atom(kind: MathSymbols.kind(of: c), text: String(c)))
            }
        }
        return out
    }

    /// The argument of ^, _, \frac…: a group, a command, or one character.
    private mutating func renderArgument() -> String {
        skipSpaces()
        guard i < chars.count else { return "" }
        if chars[i] == "{" {
            i += 1
            return Self.join(atoms(until: "}"))
        }
        if chars[i] == "\\" {
            return Self.join(command())
        }
        let c = chars[i]
        i += 1
        return String(c)
    }

    /// A raw `{…}` group's source, or nil if none follows.
    private mutating func rawGroup() -> String? {
        skipSpaces()
        guard i < chars.count, chars[i] == "{" else { return nil }
        var level = 0
        let start = i + 1
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "{" { level += 1 }
            if chars[i] == "}" {
                level -= 1
                if level == 0 {
                    i += 1
                    return String(chars[start..<(i - 1)])
                }
            }
            i += 1
        }
        return String(chars[min(start, chars.count)...])
    }

    /// An optional `[…]` argument's source.
    private mutating func optionalArgument() -> String? {
        skipSpaces()
        guard i < chars.count, chars[i] == "[" else { return nil }
        let start = i + 1
        while i < chars.count, chars[i] != "]" { i += 1 }
        let value = String(chars[min(start, chars.count)..<min(i, chars.count)])
        i = min(i + 1, chars.count)
        return value
    }

    private mutating func skipSpaces() {
        while i < chars.count, chars[i].isWhitespace { i += 1 }
    }

    private mutating func command() -> [Atom] {
        i += 1
        guard i < chars.count else { return [] }
        let first = chars[i]
        guard first.isLetter else {
            i += 1
            switch first {
            case ",", ":", ";", ">", " ", "\n": return [Atom(kind: .space, text: " ")]
            case "!", "/": return []
            case "\\": return [Atom(kind: .punctuation, text: ";")]
            case "|": return [Atom(kind: .ordinary, text: "‖")]
            case "{": return [Atom(kind: .opening, text: "{")]
            case "}": return [Atom(kind: .closing, text: "}")]
            default: return [Atom(kind: .ordinary, text: String(first))]
            }
        }
        var name = ""
        while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
        if i < chars.count, chars[i] == "*" { i += 1 }
        return atoms(forCommand: name)
    }

    private mutating func atoms(forCommand name: String) -> [Atom] {
        if let s = MathSymbols.greek[name] ?? MathSymbols.ordinary[name] { return [Atom(kind: .ordinary, text: s)] }
        if let s = MathSymbols.binary[name] { return [Atom(kind: .binary, text: s)] }
        if let s = MathSymbols.relation[name] { return [Atom(kind: .relation, text: s)] }
        if let s = MathSymbols.largeOperators[name] { return [Atom(kind: .largeOperator, text: s)] }
        if let s = MathSymbols.opening[name] { return [Atom(kind: .opening, text: s)] }
        if let s = MathSymbols.closing[name] { return [Atom(kind: .closing, text: s)] }
        if MathSymbols.functions.contains(name) { return [Atom(kind: .function, text: name)] }
        if let mark = MathSymbols.accents[name] {
            let base = renderArgument()
            return [Atom(kind: .ordinary, text: base.count == 1 ? base + mark : base)]
        }

        switch name {
        case "frac", "dfrac", "tfrac", "cfrac", "flatfrac":
            let numerator = renderArgument()
            let denominator = renderArgument()
            return [Atom(kind: .ordinary, text: Self.fraction(numerator, denominator))]
        case "sqrt":
            let index = optionalArgument().map { Self.render($0, depth: depth + 1) }
            let radicand = renderArgument()
            let prefix = index.map { Self.script($0, superscript: true) } ?? ""
            return [Atom(kind: .ordinary, text: prefix + "√" + Self.wrapped(radicand))]
        case "binom", "dbinom", "tbinom", "choose":
            let n = renderArgument()
            let k = renderArgument()
            return [Atom(kind: .ordinary, text: "(\(n) choose \(k))")]
        case "text", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal", "textup", "textsl", "textsc", "emph", "mbox", "hbox":
            return [Atom(kind: .text, text: Self.textMode(rawGroup() ?? ""))]
        case "operatorname":
            return [Atom(kind: .function, text: Self.render(rawGroup() ?? "", depth: depth + 1))]
        case "mathbb", "Bbb", "mathds":
            let content = renderArgument()
            return [Atom(kind: .ordinary, text: String(content.map { MathSymbols.doubleStruck[String($0)] ?? String($0) }.joined()))]
        case "overset", "underset", "stackrel":
            _ = renderArgument()
            return [Atom(kind: .ordinary, text: renderArgument())]
        case "not":
            let negated = Self.join(nextAtoms())
            let symbol = ["=": "≠", "∈": "∉", "<": "≮", ">": "≯", "≡": "≢", "⊂": "⊄", "⊆": "⊈", "∼": "≁", "≤": "≰", "≥": "≱"][negated]
            return [Atom(kind: .relation, text: symbol ?? negated + "\u{338}")]
        case "pmod":
            return [Atom(kind: .text, text: " (mod \(renderArgument()))")]
        case "bmod":
            return [Atom(kind: .binary, text: "mod")]
        case "textcolor", "colorbox":
            _ = rawGroup()
            return [Atom(kind: .ordinary, text: renderArgument())]
        case "begin":
            return [Atom(kind: .ordinary, text: environment(rawGroup() ?? ""))]
        case "end":
            _ = rawGroup()
            return []
        case "quad", "qquad", "enspace", "thinspace", "medspace", "thickspace":
            return [Atom(kind: .space, text: " ")]
        case "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr", "middle", "bigm", "Bigm":
            // The delimiter that follows; "." means none.
            skipSpaces()
            if i < chars.count, chars[i] == "." { i += 1; return [] }
            return nextAtoms()
        default:
            break
        }
        if MathSymbols.discardedWithArgument.contains(name) {
            _ = rawGroup()
            return []
        }
        if MathSymbols.styleCommands.contains(name) {
            return [Atom(kind: .ordinary, text: renderArgument())]
        }
        // Unknown or spacing-only command: drop it; any group that follows renders as plain content.
        return []
    }

    /// The atoms of the next single token (used after \not, \left, \right).
    private mutating func nextAtoms() -> [Atom] {
        skipSpaces()
        guard i < chars.count else { return [] }
        if chars[i] == "\\" { return command() }
        let c = chars[i]
        i += 1
        return [Atom(kind: MathSymbols.kind(of: c), text: String(c))]
    }

    /// Matrices, cases, and aligned equations: rows separated by "; ", cells by spaces.
    private mutating func environment(_ name: String) -> String {
        let base = name.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        if base == "array" || base == "alignat" || base == "tabular" { _ = rawGroup() }
        let body = rawEnvironmentBody(name)
        let rows = Self.splitTopLevel(body, on: "\\\\").map { row in
            Self.splitTopLevel(row, on: "&").map { Self.render($0, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: " ")
        }.filter { !$0.isEmpty }
        let joined = rows.joined(separator: "; ")
        switch base {
        case "pmatrix": return "(\(joined))"
        case "bmatrix": return "[\(joined)]"
        case "Bmatrix": return "{\(joined)}"
        case "vmatrix": return "|\(joined)|"
        case "Vmatrix": return "‖\(joined)‖"
        default: return joined
        }
    }

    /// Source up to the matching `\end{name}`, consuming it.
    private mutating func rawEnvironmentBody(_ name: String) -> String {
        let open = Array("\\begin{\(name)}")
        let close = Array("\\end{\(name)}")
        var level = 1
        let start = i
        while i < chars.count {
            if chars[i] == "\\" {
                if Self.matches(chars, open, at: i) { level += 1; i += open.count; continue }
                if Self.matches(chars, close, at: i) {
                    level -= 1
                    if level == 0 {
                        let body = String(chars[start..<i])
                        i += close.count
                        return body
                    }
                    i += close.count
                    continue
                }
            }
            i += 1
        }
        return String(chars[start...])
    }

    private static func matches(_ chars: [Character], _ pattern: [Character], at index: Int) -> Bool {
        guard index + pattern.count <= chars.count else { return false }
        return chars[index..<(index + pattern.count)].elementsEqual(pattern)
    }

    /// Splits on a separator that isn't inside braces.
    private static func splitTopLevel(_ text: String, on separator: String) -> [String] {
        let chars = Array(text)
        let sep = Array(separator)
        var parts: [String] = []
        var level = 0
        var current: [Character] = []
        var k = 0
        while k < chars.count {
            if chars[k] == "{" { level += 1 } else if chars[k] == "}" { level -= 1 }
            if level == 0, matches(chars, sep, at: k), !(separator == "&" && k > 0 && chars[k - 1] == "\\") {
                parts.append(String(current))
                current = []
                k += sep.count
                continue
            }
            if chars[k] == "\\", k + 1 < chars.count, sep.first != "\\" || !matches(chars, sep, at: k) {
                current.append(chars[k])
                current.append(chars[k + 1])
                k += 2
                continue
            }
            current.append(chars[k])
            k += 1
        }
        parts.append(String(current))
        return parts
    }

    // MARK: - Output

    private static func join(_ atoms: [Atom]) -> String {
        var out = ""
        func trimTrailingSpace() { while out.last == " " { out.removeLast() } }
        var previous: MathSymbols.Kind?
        for (index, atom) in atoms.enumerated() {
            let next = atoms[(index + 1)...].first { $0.kind != .space }?.kind
            switch atom.kind {
            case .space:
                if !out.isEmpty, out.last != " " { out += " " }
                continue
            case .binary:
                let unary = previous == nil || [.binary, .relation, .opening, .punctuation, .largeOperator].contains(previous!)
                if unary {
                    out += atom.text
                } else {
                    trimTrailingSpace()
                    out += " " + atom.text + " "
                }
            case .relation:
                trimTrailingSpace()
                out += (out.isEmpty ? "" : " ") + atom.text + " "
            case .punctuation:
                trimTrailingSpace()
                out += atom.text + " "
            case .function, .largeOperator:
                if let previous, [.ordinary, .closing, .text].contains(previous), out.last != " " { out += " " }
                out += atom.text
                if next == .ordinary || next == .function || next == .largeOperator || (atom.kind == .largeOperator && next == .opening) {
                    out += " "
                }
            case .text:
                out += atom.text
            case .ordinary, .opening, .closing:
                out += atom.text
            }
            previous = atom.kind
        }
        return out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Superscript or subscript in Unicode, or ^(…)/_(…) when a character has no such form.
    static func script(_ text: String, superscript: Bool) -> String {
        let compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return "" }
        if superscript {
            if compact == "∘" || compact == "°" { return "°" }
            if compact.allSatisfy({ $0 == "′" }) { return compact }
        }
        let table = superscript ? MathSymbols.superscripts : MathSymbols.subscripts
        let mapped = compact.compactMap { table[$0] }
        if mapped.count == compact.count { return String(mapped) }
        let marker = superscript ? "^" : "_"
        return compact.count == 1 ? marker + compact : marker + "(" + text.trimmingCharacters(in: .whitespaces) + ")"
    }

    static func fraction(_ numerator: String, _ denominator: String) -> String {
        let n = numerator.trimmingCharacters(in: .whitespaces)
        let d = denominator.trimmingCharacters(in: .whitespaces)
        if let vulgar = MathSymbols.vulgarFractions["\(n)/\(d)"] { return vulgar }
        return wrapped(n) + "/" + wrapped(d)
    }

    /// Parenthesizes compound expressions so "a+b over c" reads (a+b)/c.
    static func wrapped(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count > 1, t.contains(where: { " +-−=×·/<>±∓,".contains($0) }) else { return t }
        if t.hasPrefix("("), t.hasSuffix(")"), !t.dropFirst().dropLast().contains(where: { $0 == "(" || $0 == ")" }) { return t }
        return "(" + t + ")"
    }

    /// Text inside \text{…}: kept as written, with nested math rendered and commands removed.
    static func textMode(_ raw: String) -> String {
        LaTeXText.inline(raw)
    }
}
