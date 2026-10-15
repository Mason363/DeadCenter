import Foundation

/// Splits plain text into paragraphs.
///
/// With blank lines, blank lines separate paragraphs and single newlines are hard wraps
/// (list items stay separate). Without blank lines, each line is a paragraph, unless the
/// text is clearly hard-wrapped at a fixed width, in which case short sentence-ending lines
/// and indented lines start paragraphs.
enum PlainTextParagraphs {
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        enumerate(text) { paragraph, _ in out.append(paragraph) }
        return out
    }

    /// Calls `body` with each paragraph and the fraction of the text consumed so far.
    static func enumerate(_ text: String, _ body: (String, Double) throws -> Void) rethrows {
        let lines = normalizedLines(text)
        guard !lines.isEmpty else { return }
        let layout = Layout(lines)
        var compounds = Set<String>()
        for line in lines.prefix(4000) { TextNormalizer.collectCompounds(in: String(line), into: &compounds) }

        var current: String?
        var previous: Substring?
        let total = Double(lines.count)

        func finish(_ index: Int) throws {
            if let paragraph = current {
                let withMath = LaTeX.convertingMath(in: TextNormalizer.clean(paragraph))
                let cleaned = strippingUnderscoreEmphasis(TextNormalizer.strippingBullet(withMath))
                if !cleaned.isEmpty { try body(cleaned, Double(index) / total) }
            }
            current = nil
        }

        for (index, line) in lines.enumerated() {
            if line.isBlankLine {
                try finish(index)
                previous = nil
                continue
            }
            if let prev = previous, current != nil, !layout.startsParagraph(line, after: prev) {
                TextNormalizer.append(line, to: &current!, compounds: compounds)
            } else {
                try finish(index)
                current = String(line)
            }
            previous = line
        }
        try finish(lines.count)
    }

    private static func normalizedLines(_ text: String) -> [Substring] {
        var t = text
        // Page and paragraph separators mean a blank line; every other line break (including CRLF) splits lines.
        if t.unicodeScalars.contains(where: { $0 == "\u{0C}" || $0 == "\u{2029}" }) {
            t = t.replacingOccurrences(of: "\u{0C}", with: "\n\n").replacingOccurrences(of: "\u{2029}", with: "\n\n")
        }
        return t.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    private static let underscoreEmphasis = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])_([^\s_](?:[^_]*[^\s_])?)_(?![\p{L}\p{N}_])"#)

    /// Plain-text italics convention (Project Gutenberg and email): "_very_" → "very".
    static func strippingUnderscoreEmphasis(_ text: String) -> String {
        guard text.contains("_") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return underscoreEmphasis.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }

    private struct Layout {
        let hasBlankLines: Bool
        let wrapWidth: Int
        let hardWrapped: Bool

        init(_ lines: [Substring]) {
            var sawText = false
            var pendingBlank = false
            var blank = false
            var lengths: [Int] = []
            for line in lines {
                if line.isBlankLine {
                    if sawText { pendingBlank = true }
                } else {
                    if pendingBlank { blank = true }
                    sawText = true
                    if lengths.count < 5000 { lengths.append(line.count) }
                }
            }
            hasBlankLines = blank
            lengths.sort()
            let width = lengths.isEmpty ? 0 : lengths[min(lengths.count - 1, lengths.count * 9 / 10)]
            let long = lengths.filter { Double($0) >= Double(width) * 0.6 }.count
            wrapWidth = width
            hardWrapped = lengths.count >= 6 && (36...110).contains(width) && Double(long) >= Double(lengths.count) * 0.6
        }

        func startsParagraph(_ line: Substring, after previous: Substring) -> Bool {
            let prev = previous.trimmingCharacters(in: .whitespaces)
            if let marker = TextNormalizer.listMarker(in: line) {
                // In hard-wrapped prose, "(1)" or "2." may just be the first word of a wrapped line.
                guard hardWrapped, !marker.isSymbol, TextNormalizer.listMarker(in: prev) == nil,
                      !TextNormalizer.endsClause(prev), Double(prev.count) >= Double(wrapWidth) * 0.75
                else { return true }
                return false
            }
            if !hasBlankLines && !hardWrapped { return true }
            guard hardWrapped else { return false }
            if TextNormalizer.endsSentence(prev), Double(prev.count) < Double(wrapWidth) * 0.75 { return true }
            // Wrapped lines run nearly to the margin; a much shorter one ends a paragraph or is a line of verse or a list.
            if Double(prev.count) < Double(wrapWidth) * 0.6 { return true }
            if !hasBlankLines, line.first == " " || line.first == "\t", previous.first != " ", previous.first != "\t" { return true }
            return false
        }
    }
}

private extension Substring {
    var isBlankLine: Bool { unicodeScalars.allSatisfy(TextNormalizer.isSpace) }
}

/// Recognizes source code, which a speed reader should skip.
enum CodeDetector {
    private static let codeLanguages: Set<String> = [
        "swift", "js", "javascript", "ts", "typescript", "jsx", "tsx", "python", "py", "ruby", "rb", "go", "rust",
        "rs", "c", "cpp", "c++", "h", "objc", "objective-c", "java", "kotlin", "kt", "cs", "csharp", "php", "sh",
        "bash", "zsh", "shell", "console", "sql", "json", "yaml", "yml", "toml", "xml", "html", "css", "scss",
        "makefile", "dockerfile", "diff", "lua", "perl", "r", "scala", "haskell", "elixir", "dart", "graphql", "ini",
    ]

    static func isCodeLanguage(_ hint: String?) -> Bool {
        guard let hint = hint?.lowercased(), !hint.isEmpty else { return false }
        return codeLanguages.contains(hint)
    }

    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return true }
        let codeLine = lines.filter { line in
            line.hasSuffix(";") || line.hasSuffix("{") || line.hasSuffix("}") || line.hasSuffix(")") && line.contains("(")
                || line.hasPrefix("//") || line.hasPrefix("#include") || line.hasPrefix("import ") || line.hasPrefix("from ")
                || line.hasPrefix("def ") || line.hasPrefix("func ") || line.hasPrefix("let ") || line.hasPrefix("var ")
                || line.hasPrefix("const ") || line.hasPrefix("$ ") || line.hasPrefix("return ") || line.contains("=>")
                || line.contains("==") || line.contains("->") || line.contains("</")
        }.count
        var symbols = 0, letters = 0
        for scalar in text.unicodeScalars {
            if "{}[]<>=;/\\_|&$#*+%^~`@".unicodeScalars.contains(scalar) { symbols += 1 }
            else if scalar.properties.isAlphabetic { letters += 1 }
        }
        let symbolRatio = Double(symbols) / Double(max(letters, 1))
        return Double(codeLine) / Double(lines.count) >= 0.3 || symbolRatio > 0.12
    }
}
