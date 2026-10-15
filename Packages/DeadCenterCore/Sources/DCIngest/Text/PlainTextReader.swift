import Foundation
import DCModel

enum PlainTextReader {
    /// Streams paragraphs of plain text, a few hundred at a time.
    static func read(_ text: String, into emitter: BlockEmitter) throws {
        var count = 0
        try PlainTextParagraphs.enumerate(text) { paragraph, progress in
            emitter.emit(.paragraph(paragraph))
            count += 1
            if count.isMultiple(of: 200) {
                try Task.checkCancellation()
                emitter.progress(progress)
            }
        }
    }

    /// Plain text, Markdown, or LaTeX handed over as a string (clipboard, Services, URL scheme).
    static func readString(_ text: String, into emitter: BlockEmitter) throws {
        if LaTeXDocumentReader.looksLikeDocument(text) {
            try LaTeXDocumentReader.read(text, fallbackTitle: nil, into: emitter)
        } else if MarkdownReader.looksLikeMarkdown(text) {
            // Guess the title from the first line, without its Markdown or TeX: "# **Notes**" gives "Notes".
            let title = TextNormalizer.titleGuess(from: FrontMatter.split(text).body).map(cleanTitle)
            try MarkdownReader.read(text, baseURL: nil, fallbackTitle: title, into: emitter)
        } else {
            emitter.title(TextNormalizer.titleGuess(from: text))
            try read(text, into: emitter)
        }
    }

    private static func cleanTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*\*|__|~~|`|(?<!\w)[*_]|[*_](?!\w)"#, with: "", options: .regularExpression)
        t = LaTeX.convertingMath(in: t, markdownSafe: false)
        return t.trimmingCharacters(in: .whitespaces)
    }
}
