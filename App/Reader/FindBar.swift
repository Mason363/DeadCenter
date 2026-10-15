import AppKit
import DCEngine

/// ⌘F: a small field at the top of the reader that jumps to a word or phrase as you type.
final class FindBar: NSView, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onNext: ((_ forward: Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.alignment = .right
        for view in [icon, field, countLabel] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 10, y: (h - 14) / 2, width: 14, height: 14)
        countLabel.frame = NSRect(x: bounds.width - 62, y: (h - 15) / 2, width: 52, height: 15)
        field.frame = NSRect(x: 30, y: (h - 18) / 2, width: bounds.width - 30 - 66, height: 18)
    }

    func apply(_ palette: ReaderPalette) {
        layer?.backgroundColor = palette.text.withAlphaComponent(0.09).cgColor
        layer?.borderColor = palette.text.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 0.5
        field.textColor = palette.text
        icon.contentTintColor = palette.text.withAlphaComponent(0.5)
        countLabel.textColor = palette.text.withAlphaComponent(0.45)
        field.placeholderAttributedString = NSAttributedString(string: "Find a word", attributes: [
            .foregroundColor: palette.text.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 13),
        ])
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var query: String { field.stringValue }

    func setCount(current: Int?, total: Int) {
        if field.stringValue.isEmpty {
            countLabel.stringValue = ""
        } else if total == 0 {
            countLabel.stringValue = "None"
        } else {
            countLabel.stringValue = "\((current ?? 0) + 1)/\(total)"
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            onNext?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

extension ReadingStream {
    /// Item indices where `query` starts. Case- and accent-insensitive; the last word matches as a prefix.
    /// Words split for reading are matched whole, and spaceless scripts (Chinese, Japanese, Thai…) match anywhere.
    func matches(for query: String) -> [Int] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let chunks = searchChunks()
        if trimmed.unicodeScalars.contains(where: Self.isSpaceless) {
            let needle = Array(Self.searchKey(trimmed))
            guard !needle.isEmpty else { return [] }
            return chunks.flatMap { $0.occurrences(of: needle) }
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map { Self.searchKey(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var result: [Int] = []
        for c in chunks.indices {
            for start in chunks[c].starts where matchesSequence(words, in: chunks, chunk: c, offset: start.offset) {
                let item = chunks[c].items[start.piece]
                if result.last != item { result.append(item) }
            }
        }
        return result
    }

    /// Whether `words` read on from `offset` in `chunk`. A word may end at a hyphen inside a source
    /// word, so "well known" finds "well-known", and "well-known" finds it too.
    private func matchesSequence(_ words: [String], in chunks: [SearchChunk], chunk: Int, offset: Int) -> Bool {
        var c = chunk
        var o = offset
        for (n, word) in words.enumerated() {
            let key = chunks[c].key
            if n == words.count - 1 { return key[o...].starts(with: word) }
            let end = o + word.count
            guard end <= key.count, key[o..<end].elementsEqual(word) else { return false }
            if end == key.count {
                // On to the next word, if it follows directly with no image or title in between.
                guard c + 1 < chunks.count, chunks[c + 1].items.first == chunks[c].items.last.map({ $0 + 1 }) else { return false }
                c += 1
                o = 0
            } else if chunks[c].starts.contains(where: { $0.offset == end }) {
                o = end
            } else {
                return false
            }
        }
        return true
    }

    /// Words as they're written in the source: pieces of a split word joined back together.
    private func searchChunks() -> [SearchChunk] {
        var chunks: [SearchChunk] = []
        var previous: ReadingItem?
        for (i, item) in items.enumerated() {
            defer { previous = item }
            guard item.kind == .word else { continue }
            let source = item.sourceText
            let joins = previous?.kind == .word && !item.spaceBefore && previous?.paragraph == item.paragraph
            if !joins || chunks.isEmpty { chunks.append(SearchChunk()) }
            let before = previous?.sourceText.last
            // Inside a word, a search can still start after a hyphen or dash ("known" in "well-known")
            // or at a script change ("Swift" inside Chinese text).
            let startsWord = !joins || before.map { SearchChunk.joiners.contains($0) } == true
                || before?.unicodeScalars.first.map(Self.isSpaceless) == true
                || source.unicodeScalars.first.map(Self.isSpaceless) == true
            chunks[chunks.count - 1].append(i, source: source, startsWord: startsWord)
        }
        return chunks
    }

    static func searchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Scripts written without spaces between words.
    private static func isSpaceless(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x2E80...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: true
        default: false
        }
    }
}

/// One source word: its items and their folded text, laid end to end.
private struct SearchChunk {
    static let joiners: Set<Character> = ["-", "‐", "‑", "–", "—", "/"]

    var items: [Int] = []
    var offsets: [Int] = []
    /// Where a search may begin: the start of the word and after each hyphen or dash inside it.
    var starts: [(offset: Int, piece: Int)] = []
    var key: [Character] = []

    mutating func append(_ item: Int, source: String, startsWord: Bool) {
        let base = key.count
        items.append(item)
        offsets.append(base)
        if startsWord { starts.append((base, items.count - 1)) }
        for part in source.split(whereSeparator: Self.joiners.contains) where part.startIndex > source.startIndex {
            let offset = base + ReadingStream.searchKey(String(source[..<part.startIndex])).count
            if !ReadingStream.searchKey(String(part)).isEmpty, starts.last?.offset != offset {
                starts.append((offset, items.count - 1))
            }
        }
        key.append(contentsOf: ReadingStream.searchKey(source))
    }

    /// The items where `needle` begins, once per item.
    func occurrences(of needle: [Character]) -> [Int] {
        guard !needle.isEmpty, needle.count <= key.count else { return [] }
        var found: [Int] = []
        var piece = 0
        for start in 0...(key.count - needle.count) where key[start..<start + needle.count].elementsEqual(needle) {
            while piece + 1 < offsets.count, offsets[piece + 1] <= start { piece += 1 }
            if found.last != items[piece] { found.append(items[piece]) }
        }
        return found
    }
}

extension ReadingStream {
    /// The item holding the `n`th whitespace-separated word of the page's text, counting words the
    /// way the page lays them out (split long words rejoin, titles hold several words).
    func itemIndex(forWord n: Int) -> Int? {
        var count = 0
        var lastParagraph = -1
        for (i, item) in items.enumerated() {
            let pieces = item.sourceText.split(whereSeparator: \.isWhitespace).count
            let startsWord = i == 0 || item.kind != .word || item.spaceBefore || item.paragraph != lastParagraph
            let words = max(startsWord ? pieces : pieces - 1, 0)
            if count + words > n { return i }
            count += words
            lastParagraph = item.paragraph
        }
        return nil
    }
}
