import Foundation
import DCModel

/// Markdown via Foundation's CommonMark parser, walking each run's `presentationIntent`.
///
/// Before parsing, fenced code is removed (a speed reader can't read code), TeX math is rendered
/// to Unicode (and escaped so Markdown leaves it alone), and text without blank lines gets one
/// paragraph per line, as in plain text.
enum MarkdownReader {
    static func read(_ source: String, baseURL: URL?, fallbackTitle: String?, into emitter: BlockEmitter) throws {
        let (frontMatterTitle, body) = FrontMatter.split(source)
        emitter.title(frontMatterTitle ?? fallbackTitle)

        let chunks = chunked(prepared(body))
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            emitter.emit(parse(chunk, baseURL: baseURL))
            emitter.progress(Double(index + 1) / Double(chunks.count))
        }
    }

    static func blocks(from markdown: String, baseURL: URL?) -> [Block] {
        parse(prepared(markdown), baseURL: baseURL)
    }

    private static func parse(_ markdown: String, baseURL: URL?) -> [Block] {
        // An image with empty alt text would have no characters to carry its URL.
        let source = markdown.replacingOccurrences(of: "![](", with: "![\(MarkdownBlockBuilder.emptyAlt)](")
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: source, options: options, baseURL: baseURL) else {
            return PlainTextParagraphs.split(markdown).map(Block.paragraph)
        }
        var builder = MarkdownBlockBuilder(baseURL: baseURL)
        return builder.build(attributed)
    }

    /// Removes fenced code, renders math, and keeps one paragraph per line when there are no blank lines.
    static func prepared(_ markdown: String) -> String {
        var kept: [Substring] = []
        var fence: (marker: Character, length: Int)?
        for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.drop { $0 == " " }
            let indent = line.count - trimmed.count
            if let open = fence {
                let run = trimmed.prefix { $0 == open.marker }.count
                if run >= open.length, trimmed.dropFirst(run).allSatisfy(\.isWhitespace) { fence = nil }
                continue
            }
            if indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix { $0 == marker }.count
                if run >= 3, marker == "~" || !trimmed.dropFirst(run).contains("`") {
                    fence = (marker, run)
                    kept.append("")
                    continue
                }
            }
            kept.append(line)
        }

        let text = LaTeX.convertingMath(in: kept.joined(separator: "\n"), markdownSafe: true)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.firstIndex(where: { !$0.isBlankLine }),
              let last = lines.lastIndex(where: { !$0.isBlankLine }), last > first,
              !lines[first...last].contains(where: \.isBlankLine)
        else { return text }

        // No blank lines: each line is its own paragraph. Table rows must stay together.
        var out = ""
        for (index, line) in lines.enumerated() {
            out += line
            guard index + 1 < lines.count else { break }
            let next = lines[index + 1]
            out += isTableRow(line) && isTableRow(next) ? "\n" : "\n\n"
        }
        return out
    }

    private static func isTableRow(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") || (t.contains("|") && t.hasSuffix("|"))
    }

    /// Splits very large documents at headings so the first part can be read while the rest parses.
    private static func chunked(_ text: String) -> [String] {
        guard text.utf8.count > 300_000, !hasReferenceDefinitions(text) else { return [text] }
        var chunks: [String] = []
        var current = ""
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("#"), current.utf8.count > 100_000 {
                chunks.append(current)
                current = ""
            }
            current += line
            current += "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func hasReferenceDefinitions(_ text: String) -> Bool {
        text.range(of: #"(?m)^ {0,3}\[[^\]]+\]:\s*\S"#, options: .regularExpression) != nil
    }

    // MARK: - Detection

    /// Any Markdown construct: emphasis, code, headings, lists, quotes, links, images, tables, rules.
    /// Pasted text is often Markdown (chat answers, notes); a single marker is enough to clean it up.
    private static let markdownSignals: [NSRegularExpression] = [
        #"(\*\*|__)(?=\S)[^\n]*?\S\1"#,                                  // **bold**, __bold__
        #"(?<![\*\w])\*(?=[^\s*])[^*\n]*[^\s*]\*(?![\*\w])"#,               // *emphasis*
        #"(?<![\w_])_(?=[^\s_])[^_\n]*[^\s_]_(?![\w_])"#,                   // _emphasis_
        #"(?<![\*\w])\*[^\s*]\*(?![\*\w])|(?<![\w_])_[^\s_]_(?![\w_])"#,    // *x*, _x_
        #"`[^`\n]+`"#,                                                    // `code`
        #"(?m)^ {0,3}(```|~~~)"#,                                           // fenced code
        #"(?m)^ {0,3}#{1,6}[ \t]+\S"#,                                      // # heading
        #"(?m)^ {0,3}([-*+]|\d{1,3}[.)])[ \t]+\S"#,                          // list item
        #"(?m)^ {0,3}>[ \t]?\S"#,                                           // > quote
        #"!?\[[^\]\n]*\]\([^)\s]+(\s+"[^"]*")?\)"#,                          // [link](url), ![alt](src)
        #"(?m)^ {0,3}\|?[ \t]*:?-{3,}:?[ \t]*(\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$"#, // table separator
        #"(?m)^ {0,3}\|.*\|[ \t]*$"#,                                       // | table | row |
        #"(?m)^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#,                          // --- rule
    ].map { try! NSRegularExpression(pattern: $0) }

    static func looksLikeMarkdown(_ text: String) -> Bool {
        let sample = String(text.prefix(200_000))
        let range = NSRange(sample.startIndex..., in: sample)
        return markdownSignals.contains { $0.firstMatch(in: sample, range: range) != nil }
    }
}

private extension Substring {
    var isBlankLine: Bool { allSatisfy(\.isWhitespace) }
}

/// YAML (`---`) or TOML (`+++`) front matter at the top of a Markdown file.
enum FrontMatter {
    static func split(_ text: String) -> (title: String?, body: String) {
        let trimmed = text.drop { $0 == "\u{FEFF}" }
        for fence in ["---", "+++"] where trimmed.hasPrefix(fence + "\n") || trimmed.hasPrefix(fence + "\r\n") {
            let lines = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard let end = lines.dropFirst().prefix(300).firstIndex(where: {
                let l = $0.trimmingCharacters(in: .whitespaces)
                return l == fence || (fence == "---" && l == "...")
            }) else { continue }
            var title: String?
            for line in lines[1..<end] {
                let parts = line.split(separator: fence == "+++" ? "=" : ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "title" else { continue }
                title = parts[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            }
            return (title?.isEmpty == false ? title : nil, lines[(end + 1)...].joined(separator: "\n"))
        }
        return (nil, String(trimmed))
    }
}

/// Groups attributed runs into blocks by their innermost presentation intent.
private struct MarkdownBlockBuilder {
    static let emptyAlt = "\u{FFFC}"

    let baseURL: URL?
    private var blocks: [Block] = []
    private var text = ""
    private var deferredImages: [ImageAsset] = []
    private var currentIdentity: Int?
    private var currentKind: PresentationIntent.Kind?
    /// Cells of the table row being read, and the identity of the current cell.
    private var cells: [String] = []
    private var currentCell: Int?

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    mutating func build(_ attributed: AttributedString) -> [Block] {
        for run in attributed.runs {
            let fragment = String(attributed[run.range].characters)
            let inlineIntent = run.inlinePresentationIntent ?? []

            if run.presentationIntent == nil, inlineIntent.contains(.blockHTML) {
                finishBlock()
                let walker = HTMLBlockWalker(options: .init(resolver: URLImageResolver(baseURL: baseURL)))
                blocks.append(contentsOf: walker.walk(HTMLParser.parse(fragment)))
                continue
            }
            // Table cells are grouped by row: one paragraph per row.
            let components = run.presentationIntent?.components ?? []
            var block = components.first
            var cell: Int?
            if case .tableCell? = components.first?.kind, components.count > 1 {
                cell = components[0].identity
                block = components[1]
            }
            if block?.identity != currentIdentity {
                finishBlock()
                currentIdentity = block?.identity
                currentKind = block?.kind
            }
            if let cell, cell != currentCell {
                if currentCell != nil { cells.append(text); text = "" }
                currentCell = cell
            }

            if inlineIntent.contains(.softBreak) || inlineIntent.contains(.lineBreak) {
                text += " "
            } else if inlineIntent.contains(.inlineHTML) {
                handleInlineHTML(fragment)
            } else if let url = run.imageURL {
                addImage(url, alt: fragment == Self.emptyAlt ? nil : fragment)
            } else {
                text += fragment
            }
        }
        finishBlock()
        return blocks
    }

    private mutating func finishBlock() {
        defer {
            text = ""
            cells = []
            currentCell = nil
            blocks.append(contentsOf: deferredImages.map(Block.image))
            deferredImages.removeAll()
        }
        if case .tableRow? = currentKind { return finishRow() }
        if case .tableHeaderRow? = currentKind { return finishRow() }
        guard let kind = currentKind, !text.isBlank else { return }
        let text = Self.scrubbed(text)
        switch kind {
        case .header(let level):
            blocks.append(.heading(text, level: level))
        case .codeBlock(let hint):
            if CodeDetector.isCodeLanguage(hint) || CodeDetector.looksLikeCode(text) { return }
            blocks.append(contentsOf: PlainTextParagraphs.split(text).map(Block.paragraph))
        case .thematicBreak:
            return
        default:
            blocks.append(.paragraph(text))
        }
    }

    private mutating func finishRow() {
        let row = (cells + [text]).map { TextNormalizer.clean(Self.scrubbed($0)) }.filter { !$0.isEmpty }
        if !row.isEmpty { blocks.append(.paragraph(row.joined(separator: ", "))) }
    }

    /// Emphasis markers and backticks CommonMark left unmatched ("**unclosed").
    private static func scrubbed(_ text: String) -> String {
        guard text.contains("**") || text.contains("__") || text.contains("`") else { return text }
        return text.replacingOccurrences(of: #"\*{2,}|_{2,}|`+"#, with: "", options: .regularExpression)
    }

    private mutating func handleInlineHTML(_ tag: String) {
        let lower = tag.lowercased()
        if lower.hasPrefix("<br") {
            text += " "
        } else if lower.hasPrefix("<img"), let img = HTMLParser.parse(tag).first(where: { $0.localName == "img" }),
                  let src = img.attribute("src"), let url = URL(string: src, relativeTo: baseURL) {
            addImage(url.absoluteURL, alt: img.attribute("alt"))
        }
    }

    private mutating func addImage(_ url: URL, alt: String?) {
        guard !Self.isBadge(url) else { return }
        let source: ImageAsset.Source?
        switch url.scheme?.lowercased() {
        case "file": source = URLImageResolver.localSource(url)
        case "data": source = DataURI.decode(url.absoluteString).map { .data($0) }
        case "http", "https": source = .url(url)
        default: source = nil
        }
        guard let source else { return }
        let asset: ImageAsset
        if case .data(let data) = source {
            guard let decoded = ImageData.asset(data, caption: alt) else { return }
            asset = decoded
        } else {
            asset = ImageAsset(source: source, caption: alt)
        }
        if text.isBlank {
            blocks.append(.image(asset))
        } else {
            deferredImages.append(asset)
        }
    }

    /// Status badges in READMEs (build passing, version…) aren't content.
    private static func isBadge(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return ["shields.io", "badge.fury.io", "badgen.net", "travis-ci", "circleci.com", "codecov.io", "coveralls.io", "deepsource"]
            .contains { host.contains($0) } || path.contains("badge")
    }
}
