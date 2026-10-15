import Foundation

/// Turns raw extracted text into the clean, single-spaced, NFC prose the engine expects.
enum TextNormalizer {
    /// Collapses all whitespace (including line breaks) to single spaces, drops invisible and
    /// control characters, expands typographic ligatures, and NFC-normalizes.
    static func clean(_ text: some StringProtocol) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if let expansion = ligatures[v] {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(contentsOf: expansion.unicodeScalars)
                continue
            }
            if isSpace(scalar) {
                pendingSpace = true
                continue
            }
            if isInvisible(v) { continue }
            var scalar = scalar
            if (0x80...0x9F).contains(v) {
                // C1 controls usually come from Windows-1252 text decoded as Latin-1.
                guard let mapped = windows1252C1[v] else { continue }
                scalar = mapped
            } else if v < 0x20 || v == 0x7F {
                continue
            }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
        return String(out).precomposedStringWithCanonicalMapping
    }

    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            true
        default:
            false
        }
    }

    private static func isInvisible(_ v: UInt32) -> Bool {
        switch v {
        case 0xAD, 0x34F, 0x61C, 0x180E, 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x2064,
             0x2066...0x2069, 0xFEFF, 0xFFF9...0xFFFD, 0xE000...0xF8FF:
            true
        default:
            false
        }
    }

    private static let ligatures: [UInt32: String] = [
        0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl", 0xFB03: "ffi", 0xFB04: "ffl", 0xFB05: "st", 0xFB06: "st",
    ]

    private static let windows1252C1: [UInt32: Unicode.Scalar] = [
        0x80: "\u{20AC}", 0x82: "\u{201A}", 0x83: "\u{0192}", 0x84: "\u{201E}", 0x85: "\u{2026}",
        0x86: "\u{2020}", 0x87: "\u{2021}", 0x88: "\u{02C6}", 0x89: "\u{2030}", 0x8A: "\u{0160}",
        0x8B: "\u{2039}", 0x8C: "\u{0152}", 0x8E: "\u{017D}", 0x91: "\u{2018}", 0x92: "\u{2019}",
        0x93: "\u{201C}", 0x94: "\u{201D}", 0x95: "\u{2022}", 0x96: "\u{2013}", 0x97: "\u{2014}",
        0x98: "\u{02DC}", 0x99: "\u{2122}", 0x9A: "\u{0161}", 0x9B: "\u{203A}", 0x9C: "\u{0153}",
        0x9E: "\u{017E}", 0x9F: "\u{0178}",
    ]

    // MARK: - Joining wrapped lines

    /// Joins the next line of a hard-wrapped paragraph onto the text so far, undoing
    /// end-of-line hyphenation and leaving no space between CJK characters.
    ///
    /// - Parameter compounds: lowercased hyphenated words seen elsewhere in the document;
    ///   a line-end hyphen that forms one of them is kept.
    static func join(_ head: String, _ tail: some StringProtocol, compounds: Set<String> = []) -> String {
        var result = head
        append(tail, to: &result, compounds: compounds)
        return result
    }

    /// In-place `join`, linear in the length of `tail`.
    static func append(_ tail: some StringProtocol, to head: inout String, compounds: Set<String> = []) {
        while let last = head.unicodeScalars.last, isSpace(last) { head.unicodeScalars.removeLast() }
        let b = Substring(tail).drop { $0.unicodeScalars.allSatisfy(isSpace) }
        guard let last = head.unicodeScalars.last else { head = String(b); return }
        guard let first = b.unicodeScalars.first else { return }

        if hyphens.contains(last.value) {
            let letters = head.unicodeScalars.dropLast().reversed().prefix { $0.properties.isAlphabetic }
            if !letters.isEmpty {
                let dropsAlways = last.value == 0xAD || last.value == 0xAC
                if first.properties.isLowercase {
                    let stem = String(String.UnicodeScalarView(letters.reversed()))
                    let continuation = String(String.UnicodeScalarView(b.unicodeScalars.prefix { $0.properties.isAlphabetic }))
                    if !dropsAlways, compounds.contains((stem + "-" + continuation).lowercased()) {
                        head += b
                        return
                    }
                    head.unicodeScalars.removeLast()
                    head += b
                    return
                }
                if dropsAlways { head.unicodeScalars.removeLast() }
                head += b
                return
            }
        }
        if last.value == 0x2014 || last.value == 0x2013 || last.value == 0x2F || isCJK(last) || isCJK(first) {
            head += b
            return
        }
        head += " "
        head += b
    }

    private static let hyphens: Set<UInt32> = [0x2D, 0xAD, 0x2010, 0xAC]

    /// Adds every hyphenated word in `line` (such as "well-known") to `compounds`.
    static func collectCompounds(in line: String, into compounds: inout Set<String>) {
        guard line.contains("-") else { return }
        for token in line.split(whereSeparator: { $0 == " " }) where token.contains("-") {
            let word = token.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-")))
            let parts = word.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(\.properties.isAlphabetic) })
            else { continue }
            for i in 0..<(parts.count - 1) {
                compounds.insert("\(parts[i])-\(parts[i + 1])".lowercased())
            }
        }
    }

    /// Han, kana, and CJK punctuation: scripts written without spaces between words.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFF60, 0xFFE0...0xFFEF, 0x20000...0x3FFFF:
            true
        default:
            false
        }
    }

    // MARK: - Line classification

    /// Whether the line ends a sentence (ignoring closing quotes and brackets).
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.reversed().first(where: { !closers.contains($0.value) && !isSpace($0) })
        else { return false }
        return terminalPunctuation.contains(last.value)
    }

    /// Like `endsSentence`, also accepting a semicolon.
    static func endsClause(_ text: String) -> Bool {
        endsSentence(text) || text.trimmingTrailingSpaces().hasSuffix(";")
    }

    private static let closers: Set<UInt32> = [0x22, 0x27, 0x29, 0x5D, 0xBB, 0x2019, 0x201D, 0x300D, 0x300F, 0xFF09, 0x2A, 0x2020]
    private static let terminalPunctuation: Set<UInt32> = [0x2E, 0x21, 0x3F, 0x3A, 0x2026, 0x3002, 0xFF01, 0xFF1F, 0xFF1A]

    /// Length of a leading list marker ("• ", "- ", "1. ", "a) ", "(iv) ") in `line`, if any.
    static func listMarker(in line: some StringProtocol) -> (length: Int, isSymbol: Bool)? {
        let chars = Array(line.prefix(12))
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        guard i < chars.count else { return nil }
        func followedBySpace(_ j: Int) -> Bool { j < chars.count && (chars[j] == " " || chars[j] == "\t" || chars[j] == "\u{00A0}") }

        if "•◦▪▫●○■□‣⁃∙·–—-−*+▸►➤➢◆◇❖✓✔→".contains(chars[i]) {
            guard followedBySpace(i + 1) else { return nil }
            var j = i + 1
            while j < chars.count, chars[j] == " " || chars[j] == "\t" || chars[j] == "\u{00A0}" { j += 1 }
            return (j, true)
        }
        var j = i
        let opensParen = chars[j] == "("
        if opensParen { j += 1 }
        let tokenStart = j
        while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
        var digits = j - tokenStart
        if digits == 0, opensParen {
            while j < chars.count, "ivxlc".contains(chars[j]) { j += 1 }
            digits = j - tokenStart
        }
        if digits == 0, j < chars.count, chars[j].isLowercase, chars[j].isASCII {
            j += 1
            digits = 1
        }
        guard digits > 0, digits <= 3, j < chars.count else { return nil }
        if opensParen {
            guard chars[j] == ")" else { return nil }
        } else {
            guard chars[j] == "." || chars[j] == ")" else { return nil }
        }
        guard followedBySpace(j + 1) else { return nil }
        return (j + 2, false)
    }

    /// Removes a leading bullet symbol ("• item" → "item"). Dashes are kept: they also open dialogue.
    static func strippingBullet(_ text: String) -> String {
        guard let marker = listMarker(in: text), marker.isSymbol,
              let first = text.drop(while: { $0 == " " || $0 == "\t" }).first, !"–—−".contains(first)
        else { return text }
        return String(text.dropFirst(marker.length)).trimmingLeadingSpaces()
    }

    /// A lowercase alphanumeric key for loosely comparing titles and headings.
    static func comparisonKey(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }))
    }

    /// A short title from the first meaningful line of some text.
    static func titleGuess(from text: some StringProtocol, limit: Int = 80) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            var t = clean(line)
            while let first = t.first, "#>*-+= ".contains(first) { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            return truncated(t, limit: limit)
        }
        return nil
    }

    static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}

extension String {
    func trimmingTrailingSpaces() -> String {
        var s = Substring(self)
        while let last = s.unicodeScalars.last, TextNormalizer.isSpace(last) { s = Substring(s.unicodeScalars.dropLast()) }
        return String(s)
    }

    func trimmingLeadingSpaces() -> String {
        var s = Substring(self)
        while let first = s.unicodeScalars.first, TextNormalizer.isSpace(first) { s = Substring(s.unicodeScalars.dropFirst()) }
        return String(s)
    }

    var isBlank: Bool { unicodeScalars.allSatisfy(TextNormalizer.isSpace) }
}
