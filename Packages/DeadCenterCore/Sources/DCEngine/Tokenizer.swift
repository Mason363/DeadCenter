import Foundation
import NaturalLanguage
import DCModel

/// Turns blocks into reading items: sentence and word segmentation, long-word splitting,
/// CJK/Thai word segmentation, and pause weights.
///
/// Stateful across batches (sentence, paragraph and chapter numbering continue), so feed it
/// the blocks of one document in order. Not thread-safe; use from one task.
public final class Tokenizer {
    /// Words longer than this are split into pieces.
    public static let longWordThreshold = 13
    /// Target maximum length of a split piece.
    public static let pieceLength = 10

    private var sentence = 0
    private var paragraph = 0
    private var chapter = -1
    private var emitted = 0

    private let sentenceTokenizer = NLTokenizer(unit: .sentence)
    private let wordTokenizer = NLTokenizer(unit: .word)
    private let hyphenationLocale: CFLocale

    public init() {
        let current = Locale.current as CFLocale
        hyphenationLocale = CFStringIsHyphenationAvailableForLocale(current)
            ? current : Locale(identifier: "en_US") as CFLocale
    }

    public func tokenize(_ blocks: [Block]) -> TokenBatch {
        var batch = TokenBatch()
        for block in blocks {
            switch block {
            case .chapter(let title):
                let text = Self.collapseWhitespace(title)
                guard !text.isEmpty else { continue }
                chapter += 1
                batch.chapters.append(Chapter(title: text, itemIndex: emitted + batch.items.count))
                batch.items.append(ReadingItem(kind: .title, text: text, sentence: sentence,
                                               paragraph: paragraph, chapter: chapter))
                sentence += 1
                paragraph += 1
            case .heading(let text, _):
                appendText(text, heading: true, to: &batch)
            case .paragraph(let text):
                appendText(text, heading: false, to: &batch)
            case .image(let asset):
                batch.items.append(ReadingItem(kind: .image, text: asset.caption ?? "", sentence: sentence,
                                               paragraph: paragraph, chapter: chapter, image: asset))
                sentence += 1
                paragraph += 1
            }
        }
        emitted += batch.items.count
        return batch
    }

    // MARK: - Text

    private func appendText(_ raw: String, heading: Bool, to batch: inout TokenBatch) {
        let text = Self.collapseWhitespace(TextShaping.prepare(raw))
        guard !text.isEmpty else { return }
        let firstItem = batch.items.count

        sentenceTokenizer.string = text
        var ranges = sentenceTokenizer.tokens(for: text.startIndex..<text.endIndex)
        if ranges.isEmpty { ranges = [text.startIndex..<text.endIndex] }

        var atParagraphStart = true
        // Open brackets and quotes, innermost last. Reset per paragraph.
        var enclosures: [Character] = []
        var enclosedWords = 0

        func closeMatching(_ closers: [Character]) -> Bool {
            var closedAny = false
            for c in closers {
                guard let top = enclosures.last, TextShaping.openers[top] == c else { continue }
                enclosures.removeLast()
                closedAny = true
            }
            if enclosures.isEmpty { enclosedWords = 0 }
            return closedAny
        }

        for range in ranges {
            let before = batch.items.count
            for chunk in text[range].split(whereSeparator: \.isWhitespace) {
                let token = String(chunk)
                if TextShaping.isSeparator(token) { continue }
                if TextShaping.isLoneDash(token) || token == "…" {
                    attachPause(token == "…" ? "…" : "—", to: &batch, after: firstItem)
                    continue
                }
                let shape = TextShaping.enclosure(of: token)
                if !shape.hasCore {
                    // Brackets or quotes on their own: open, or close what's open.
                    for c in token {
                        if let top = enclosures.last, TextShaping.openers[top] == c {
                            enclosures.removeLast()
                            if let last = batch.items.indices.last, last >= firstItem { batch.items[last].extra += 0.25 }
                        } else if TextShaping.openers[c] != nil {
                            enclosures.append(c)
                        }
                    }
                    continue
                }
                // A straight quote at the end closes rather than opens.
                var opened = shape.openers
                if opened.last == "\"", shape.closers.last == "\"", opened.count == 1, enclosures.last == "\"" {
                    opened = []
                }
                enclosures.append(contentsOf: opened)
                if !enclosures.isEmpty { enclosedWords += 1 }
                if enclosedWords > 150 {
                    // Almost certainly an unbalanced mark; stop decorating.
                    enclosures.removeAll()
                    enclosedWords = 0
                }
                let enclosure = enclosures.last
                let parts = pieces(of: token)
                for (i, piece) in parts.enumerated() {
                    var extra = piece.extra
                    if i == 0, !opened.isEmpty { extra += 0.12 }
                    batch.items.append(ReadingItem(
                        kind: .word, text: piece.text, extra: extra,
                        spaceBefore: !atParagraphStart && (i == 0 || piece.spaceBefore),
                        sentence: sentence, paragraph: paragraph, chapter: chapter,
                        addedHyphen: piece.addedHyphen, enclosure: enclosure))
                    atParagraphStart = false
                }
                if closeMatching(shape.closers), let last = batch.items.indices.last {
                    batch.items[last].extra += 0.25
                }
            }
            if batch.items.count > before {
                let factor = Self.complexity(of: batch.items[before...])
                for i in before..<batch.items.count { batch.items[i].complexity = factor }
                sentence += 1
            }
        }

        guard batch.items.count > firstItem else { return }
        let last = batch.items.count - 1
        batch.items[last].extra = heading
            ? max(batch.items[last].extra, 1.0) + 1.2
            : max(batch.items[last].extra, 1.2) + 0.9
        paragraph += 1
    }

    /// A lone "—" or "…" between words joins the word before it as a pause.
    private func attachPause(_ mark: String, to batch: inout TokenBatch, after first: Int) {
        guard let i = batch.items.indices.last, i >= first, batch.items[i].kind == .word,
              !batch.items[i].addedHyphen else { return }
        // A thin space keeps "word —" from reading as one hyphenated word.
        if !batch.items[i].text.hasSuffix(mark) { batch.items[i].text += (mark == "—" ? "\u{2009}—" : mark) }
        batch.items[i].extra = max(batch.items[i].extra, Self.lengthExtra(batch.items[i].text) + Self.punctuationExtra(batch.items[i].text))
    }

    private struct Piece {
        var text: String
        var extra: Double
        var spaceBefore: Bool
        var addedHyphen = false
    }

    /// Splits one whitespace-delimited chunk into displayable pieces with pause weights.
    private func pieces(of chunk: String) -> [Piece] {
        if chunk.unicodeScalars.contains(where: Self.isSpacelessScript) {
            return segmentSpaceless(chunk)
        }
        if let url = TextShaping.condensedURL(chunk) {
            return [Piece(text: url, extra: 0.3 + Self.punctuationExtra(url), spaceBefore: true)]
        }
        var result: [Piece] = []
        let segments = TextShaping.splitAtDashes(chunk)
        for (s, segment) in segments.enumerated() {
            let parts = splitLongWord(segment)
            for (i, part) in parts.enumerated() {
                let isLast = i == parts.count - 1
                var extra = Self.lengthExtra(part.text)
                extra += isLast ? Self.punctuationExtra(part.text) : 0.12
                result.append(Piece(text: part.text, extra: extra, spaceBefore: s == 0 && i == 0,
                                    addedHyphen: part.addedHyphen))
            }
        }
        return result
    }

    // MARK: - Long words

    private static let breakAfter: Set<unichar> = Set("-/_—–.·".utf16)

    private func splitLongWord(_ word: String) -> [(text: String, addedHyphen: Bool)] {
        guard Self.letterCount(word) > Self.longWordThreshold else { return [(word, false)] }
        if let grouped = splitAtHyphens(word) { return grouped }
        return hyphenate(word)
    }

    /// Long hyphenated compounds split only at their own hyphens, with short parts kept together:
    /// "anti-inflammatory-drug-resistant" → "anti-", "inflammatory-", "drug-resistant".
    private func splitAtHyphens(_ word: String) -> [(text: String, addedHyphen: Bool)]? {
        var parts: [String] = []
        var current = ""
        let chars = Array(word)
        for (i, c) in chars.enumerated() {
            current.append(c)
            if c == "-" || c == "/", i > 0, i + 1 < chars.count, chars[i - 1].isLetter || chars[i - 1].isNumber,
               chars[i + 1].isLetter || chars[i + 1].isNumber {
                parts.append(current)
                current = ""
            }
        }
        parts.append(current)
        guard parts.count > 1 else { return nil }

        var groups: [String] = []
        var group = ""
        for part in parts {
            if !group.isEmpty, Self.letterCount(group) + Self.letterCount(part) > Self.longWordThreshold {
                groups.append(group)
                group = ""
            }
            group += part
        }
        if !group.isEmpty { groups.append(group) }
        // A part that is itself too long still gets hyphenated.
        return groups.flatMap { Self.letterCount($0) > Self.longWordThreshold ? hyphenate($0) : [($0, false)] }
    }

    private func hyphenate(_ word: String) -> [(text: String, addedHyphen: Bool)] {
        let ns = word as NSString
        let length = ns.length
        var pieces: [(text: String, addedHyphen: Bool)] = []
        var start = 0
        // Keep going while the remainder is too long to stand alone.
        while length - start > Self.longWordThreshold {
            let limit = start + Self.pieceLength
            var cut = -1
            var natural = false
            var i = limit
            while i > start + 3 {
                if Self.breakAfter.contains(ns.character(at: i - 1)) { cut = i; natural = true; break }
                i -= 1
            }
            if cut < 0 {
                let h = CFStringGetHyphenationLocationBeforeIndex(
                    ns, limit, CFRange(location: start, length: length - start), 0, hyphenationLocale, nil)
                if h != kCFNotFound, h > start + 3, h <= limit { cut = h }
            }
            if cut < 0 {
                // Never cut inside a composed character (emoji, combining marks).
                let composed = ns.rangeOfComposedCharacterSequence(at: limit)
                cut = composed.location > start ? composed.location : NSMaxRange(composed)
            }
            var piece = ns.substring(with: NSRange(location: start, length: cut - start))
            if !natural { piece += "-" }
            pieces.append((piece, !natural))
            start = cut
        }
        pieces.append((ns.substring(from: start), false))
        return pieces
    }

    // MARK: - CJK / Thai

    private static let openingPunctuation: Set<Character> = Set("「『（【《〈“‘([{<«")

    /// Word-segments runs written without spaces, attaching punctuation to neighbors and
    /// merging very short words so reading isn't one character at a time.
    private func segmentSpaceless(_ chunk: String) -> [Piece] {
        wordTokenizer.string = chunk
        let tokens = wordTokenizer.tokens(for: chunk.startIndex..<chunk.endIndex)
        guard !tokens.isEmpty else {
            return [Piece(text: chunk, extra: Self.punctuationExtra(chunk), spaceBefore: true)]
        }

        var words: [String] = []
        var prefix = ""
        var cursor = chunk.startIndex
        func absorbGap(upTo end: String.Index) {
            for c in chunk[cursor..<end] where !c.isWhitespace {
                if Self.openingPunctuation.contains(c) || words.isEmpty {
                    prefix.append(c)
                } else {
                    words[words.count - 1].append(c)
                }
            }
        }
        for token in tokens {
            // NLTokenizer can return overlapping or partial ranges inside emoji sequences
            // (flags, skin tones); work in whole characters and never step backwards.
            var range = chunk.rangeOfComposedCharacterSequences(for: token)
            if range.lowerBound < cursor { range = cursor..<max(cursor, range.upperBound) }
            guard !range.isEmpty else { continue }
            absorbGap(upTo: range.lowerBound)
            words.append(prefix + chunk[range])
            prefix = ""
            cursor = range.upperBound
        }
        absorbGap(upTo: chunk.endIndex)
        if !prefix.isEmpty {
            if words.isEmpty { words.append(prefix) } else { words[words.count - 1] += prefix }
        }

        // Merge short neighbors (≤ 3 letters combined) unless punctuation sits between them.
        var merged: [String] = []
        for word in words {
            if let last = merged.last,
               Self.letterCount(last) + Self.letterCount(word) <= 3,
               last.last.map(Pivot.isWordCharacter) ?? false,
               word.first.map(Pivot.isWordCharacter) ?? false {
                merged[merged.count - 1] = last + word
            } else {
                merged.append(word)
            }
        }

        // Break up anything still long (unsegmented runs).
        var result: [Piece] = []
        for word in merged {
            let chars = Array(word)
            var start = 0
            while start < chars.count {
                let end = chars.count - start > 6 ? start + 4 : chars.count
                let text = String(chars[start..<end])
                let isLast = end == chars.count
                let n = Self.letterCount(text)
                let extra = (n >= 3 ? 0.15 * Double(n - 2) : 0) + (isLast ? Self.punctuationExtra(text) : 0)
                result.append(Piece(text: text, extra: extra, spaceBefore: result.isEmpty))
                start = end
            }
        }
        return result
    }

    static func isSpacelessScript(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFF66...0xFF9F, 0x20000...0x2FA1F, 0x0E00...0x0E7F, 0x0E80...0x0EFF,
             0x1780...0x17FF, 0x1000...0x109F:
            return true
        default:
            return false
        }
    }

    // MARK: - Weights

    private static let closers: Set<Character> = Set("\"'”’)]}»›」』）】〉》")
    private static let sentenceEnders: Set<Character> = Set(".!?…。！？‼⁇⁈⁉")
    private static let clauseEnders: Set<Character> = Set(",;:、，；：")
    private static let dashes: Set<Character> = Set("—–-")
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "vs", "etc", "e.g", "i.e", "prof", "jr", "sr", "no", "fig",
        "approx", "inc", "ltd", "co", "mt", "ft", "u.s", "a.m", "p.m", "cf", "al", "vol", "pp", "ch",
    ]

    static func punctuationExtra(_ word: String) -> Double {
        var trimmed = Substring(word)
        while let last = trimmed.last, closers.contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last else { return 0 }
        if sentenceEnders.contains(last) {
            if last == "." {
                let stem = trimmed.dropLast().lowercased()
                if abbreviations.contains(stem) { return 0.15 }
                if stem.count == 1, let c = stem.first, c.isLetter { return 0.15 } // initials
            }
            return 1.2
        }
        if clauseEnders.contains(last) { return last == "," || last == "，" || last == "、" ? 0.5 : 0.65 }
        if dashes.contains(last) { return 0.4 }
        return 0
    }

    /// Sentence difficulty from word length, long-word density and numbers, normalized so typical
    /// English prose is about 1. Scripts without spaces are left at 1.
    static func complexity(of items: ArraySlice<ReadingItem>) -> Double {
        var letters = 0, long = 0, digits = 0, words = 0
        for item in items where item.kind == .word {
            if item.text.unicodeScalars.contains(where: isSpacelessScript) { return 1 }
            let n = letterCount(item.text)
            guard n > 0 else { continue }
            words += 1
            letters += n
            if n >= 9 { long += 1 }
            if item.text.contains(where: \.isNumber) { digits += 1 }
        }
        guard words >= 3 else { return 1 }
        let meanLength = Double(letters) / Double(words)
        let longRatio = Double(long) / Double(words)
        let digitRatio = Double(digits) / Double(words)
        let raw = pow(meanLength / 4.8, 0.7) * (1 + 0.6 * longRatio) * (1 + 0.3 * digitRatio) / 1.05
        return min(max(raw, 0.7), 1.45)
    }

    static func lengthExtra(_ word: String) -> Double {
        let n = letterCount(word)
        var extra = n > 6 ? min(Double(n - 6) * 0.07, 0.6) : 0
        if word.contains(where: \.isNumber) { extra += 0.3 }
        return extra
    }

    static func letterCount(_ word: String) -> Int {
        word.reduce(0) { $0 + (Pivot.isWordCharacter($1) ? 1 : 0) }
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "\u{200B}" || $0 == "\u{00AD}" })
            .joined(separator: " ")
    }
}
