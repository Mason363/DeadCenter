import Foundation
import DCModel

/// Prose LaTeX source (a paper or notes): sections become headings, lists and paragraphs read
/// as text, math is rendered, and figures, tables, code, and the preamble are skipped.
enum LaTeXDocumentReader {
    /// Whether text is a LaTeX document rather than prose that happens to contain a formula.
    static func looksLikeDocument(_ text: String) -> Bool {
        if text.contains("\\begin{document}") || text.contains("\\documentclass") { return true }
        let structural = ["\\section{", "\\section*{", "\\subsection{", "\\chapter{", "\\begin{itemize}", "\\begin{enumerate}", "\\maketitle", "\\begin{abstract}"]
        return structural.filter { text.contains($0) }.count >= 2
            || (structural.contains { text.contains($0) } && (text.contains("\\textbf{") || text.contains("\\emph{") || text.contains("\\cite")))
    }

    static func read(_ source: String, fallbackTitle: String?, into emitter: BlockEmitter) throws {
        let text = withoutComments(source)
        let blocks = blocks(from: body(of: text))
        let firstText = blocks.lazy.compactMap { block -> String? in
            if case .heading(let t, _) = block { t } else if case .paragraph(let t) = block { t } else { nil }
        }.first
        emitter.title(argument(of: "title", in: text).map(LaTeXText.inline) ?? fallbackTitle ?? firstText.flatMap { TextNormalizer.titleGuess(from: $0) })
        try Task.checkCancellation()
        emitter.emit(blocks)
        emitter.progress(1)
    }

    static func blocks(from body: String) -> [Block] {
        let hasChapters = body.contains("\\chapter")
        var blocks: [Block] = []
        for chunk in chunks(of: withoutSkippedEnvironments(body)) {
            var rest = Substring(chunk)
            if let (level, title, remainder) = sectionHeading(rest, hasChapters: hasChapters) {
                let heading = LaTeXText.inline(title)
                if !heading.isBlank { blocks.append(.heading(heading, level: level)) }
                rest = remainder
            }
            let paragraph = LaTeXText.inline(String(rest))
            if !paragraph.isBlank { blocks.append(.paragraph(paragraph)) }
        }
        return blocks
    }

    // MARK: - Structure

    private static let sectionLevels: [(String, Int)] = [
        ("part", 1), ("chapter", 1), ("section", 2), ("subsection", 3), ("subsubsection", 4), ("paragraph", 5), ("subparagraph", 6),
    ]

    /// A chunk that starts with a sectioning command: its level, title source, and the text after it.
    private static func sectionHeading(_ chunk: Substring, hasChapters: Bool) -> (Int, String, Substring)? {
        guard chunk.hasPrefix("\\") else { return nil }
        for (name, level) in sectionLevels {
            for variant in ["\\\(name)*", "\\\(name)"] where chunk.hasPrefix(variant) {
                var rest = chunk.dropFirst(variant.count)
                guard let next = rest.first, next == "{" || next == "[" || next == " " else { continue }
                rest = rest.drop { $0 == " " }
                if rest.first == "[" { rest = rest.drop { $0 != "]" }.dropFirst() }
                guard let (title, after) = group(at: rest) else { continue }
                return (hasChapters ? level : max(1, level - 1), title, after)
            }
        }
        return nil
    }

    /// Paragraph chunks: blank lines separate them, and structural commands start new ones.
    private static func chunks(of body: String) -> [String] {
        var text = body
        let breakers = ["\\part", "\\chapter", "\\section", "\\subsection", "\\subsubsection", "\\paragraph", "\\item",
                        "\\begin{", "\\end{", "\\par ", "\\par\n", "\\maketitle", "\\noindent"]
        for breaker in breakers {
            text = text.replacingOccurrences(of: breaker, with: "\n\n" + breaker)
        }
        // Math environments must stay inside their paragraph.
        for env in LaTeX.mathEnvironments {
            text = text.replacingOccurrences(of: "\n\n\\begin{\(env)}", with: " \\begin{\(env)}")
            text = text.replacingOccurrences(of: "\n\n\\end{\(env)}", with: "\\end{\(env)}")
        }
        return text.components(separatedBy: "\n\n").compactMap { chunk in
            var c = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop the begin/end markers of text environments (lists, abstract, quotes, theorems).
            while c.hasPrefix("\\begin{") || c.hasPrefix("\\end{") {
                guard let close = c.firstIndex(of: "}") else { break }
                c = String(c[c.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for command in ["\\maketitle", "\\noindent", "\\par", "\\tableofcontents"] where c.hasPrefix(command) {
                c = String(c.dropFirst(command.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return c.isEmpty ? nil : c
        }
    }

    /// Environments whose content isn't prose.
    private static let skippedEnvironments = [
        "figure", "figure*", "table", "table*", "tabular", "tabular*", "verbatim", "lstlisting", "minted", "comment",
        "thebibliography", "tikzpicture", "algorithm", "algorithmic", "filecontents",
    ]

    private static func withoutSkippedEnvironments(_ text: String) -> String {
        var result = text
        for env in skippedEnvironments {
            let open = "\\begin{\(env)}"
            let close = "\\end{\(env)}"
            while let start = result.range(of: open) {
                guard let end = result.range(of: close, range: start.upperBound..<result.endIndex) else {
                    result.removeSubrange(start.lowerBound...)
                    break
                }
                result.replaceSubrange(start.lowerBound..<end.upperBound, with: "\n\n")
            }
        }
        return result
    }

    /// The document body, without the preamble.
    private static func body(of text: String) -> String {
        guard let begin = text.range(of: "\\begin{document}") else { return text }
        let end = text.range(of: "\\end{document}", range: begin.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        return String(text[begin.upperBound..<end])
    }

    /// Removes `%` comments (an unescaped percent to the end of the line, including the newline).
    static func withoutComments(_ text: String) -> String {
        guard text.contains("%") else { return text }
        var out = ""
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var kept = ""
            var escaped = false
            var commented = false
            for ch in line {
                if ch == "%", !escaped { commented = true; break }
                escaped = ch == "\\" && !escaped
                kept.append(ch)
            }
            if commented {
                if !kept.isBlank { out += kept }
            } else {
                out += kept + "\n"
            }
        }
        return out
    }

    /// The first argument of `\name{…}` in text.
    private static func argument(of name: String, in text: String) -> String? {
        guard let range = text.range(of: "\\\(name){") else { return nil }
        return group(at: text[text.index(before: range.upperBound)...])?.0
    }

    /// A balanced `{…}` group at the start of text: its content and the remainder.
    private static func group(at text: Substring) -> (String, Substring)? {
        guard text.first == "{" else { return nil }
        var level = 0
        var index = text.startIndex
        var escaped = false
        while index < text.endIndex {
            let ch = text[index]
            if !escaped {
                if ch == "{" { level += 1 }
                if ch == "}" {
                    level -= 1
                    if level == 0 {
                        let content = String(text[text.index(after: text.startIndex)..<index])
                        return (content, text[text.index(after: index)...])
                    }
                }
            }
            escaped = ch == "\\" && !escaped
            index = text.index(after: index)
        }
        return nil
    }
}
