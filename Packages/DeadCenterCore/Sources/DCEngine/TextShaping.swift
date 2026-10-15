import Foundation

/// Punctuation that needs more care than "attach it to the word": dashes, separators, links,
/// citation markers, and the brackets and quotes that enclose asides.
public enum TextShaping {
    // MARK: - Paragraph cleanup

    private static let citation = try! NSRegularExpression(
        pattern: #"\s?\[(?:\d+(?:\s*[,–\-]\s*\d+)*|[a-z]|[ivx]{1,4}|citation needed|clarification needed|edit|note \d+|nb \d+|sic|\?)\]"#,
        options: [.caseInsensitive])
    private static let typewriterDash = try! NSRegularExpression(pattern: #"(?<=[^\s\-])[ \t]*(?<!-)-{2,3}(?!-)[ \t]*(?=[^\s\-])"#)
    private static let link = try! NSRegularExpression(pattern: #"(?i)(?:https?://|www\.)[^\s<>"]+"#)
    private static let dots = try! NSRegularExpression(pattern: #"\.{3,}"#)

    /// Removes citation markers ("[12]", "[citation needed]"), condenses links to their site,
    /// turns "--" into an em dash and "..." into "…".
    static func prepare(_ text: String) -> String {
        var s = text
        if s.contains("://") || s.contains("www.") { s = condensingLinks(in: s) }
        if s.contains("[") { s = replace(citation, in: s, with: "") }
        if s.contains("--") { s = replace(typewriterDash, in: s, with: "—") }
        if s.contains("...") { s = replace(dots, in: s, with: "…") }
        return s
    }

    /// Before sentence splitting, so a "?" inside a link doesn't end a sentence.
    private static func condensingLinks(in s: String) -> String {
        var out = s
        for match in link.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let range = Range(match.range, in: s), let short = condensedURL(String(s[range])) else { continue }
            out.replaceSubrange(range, with: short)
        }
        return out
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    // MARK: - Tokens

    private static let separatorCharacters: Set<Character> = Set("-_=*~#•·.+<>|/\\—–")
    private static let dashCharacters: Set<Character> = Set("—–-‒―")

    /// Decorative runs like "-----", "=====", "* * *" pieces, "•••": not words.
    static func isSeparator(_ token: String) -> Bool {
        token.count >= 2 && token.allSatisfy { separatorCharacters.contains($0) }
    }

    /// A dash standing between words ("word — word"): a pause, not a word of its own.
    static func isLoneDash(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 3 && token.allSatisfy { dashCharacters.contains($0) }
    }

    /// Splits after em dashes (and en dashes between words, not number ranges like 1990–2000)
    /// so "this—that" reads as "this—" then "that".
    static func splitAtDashes(_ token: String) -> [String] {
        guard token.contains("—") || token.contains("–") else { return [token] }
        let chars = Array(token)
        var parts: [String] = []
        var current = ""
        for (i, c) in chars.enumerated() {
            current.append(c)
            let isEm = c == "—"
            let isWordEn = c == "–" && i > 0 && i + 1 < chars.count
                && !(chars[i - 1].isNumber && chars[i + 1].isNumber)
            if (isEm || isWordEn), i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1].isNumber
                || openers[chars[i + 1]] != nil {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.filter { $0.contains(where: { $0.isLetter || $0.isNumber }) || $0.count > 1 }
    }

    /// "https://www.example.com/a/b?c=1" → "example.com/…" (trailing punctuation kept).
    static func condensedURL(_ token: String) -> String? {
        let lower = token.lowercased()
        let hasScheme = lower.contains("://")
        guard hasScheme || lower.hasPrefix("www.") else { return nil }
        var core = Substring(token)
        var trailing = ""
        while let last = core.last, ".,;:!?)]\"'”’".contains(last) {
            trailing = String(last) + trailing
            core = core.dropLast()
        }
        var leading = ""
        while let first = core.first, "([\"'“‘".contains(first) {
            leading.append(first)
            core = core.dropFirst()
        }
        let candidate = hasScheme ? String(core) : "https://" + core
        guard let components = URLComponents(string: candidate), var host = components.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let more = !path.isEmpty || components.query != nil
        return leading + host + (more ? "/…" : "") + trailing
    }

    // MARK: - Enclosures

    /// Opening marks and their closing partners. Straight double quotes close themselves.
    public static let openers: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "“": "”", "‘": "’", "«": "»", "‹": "›", "„": "“",
        "「": "」", "『": "』", "（": "）", "【": "】", "《": "》", "〈": "〉", "\"": "\"",
    ]
    private static let closers: Set<Character> = Set(openers.values)
    private static let trailingPunctuation: Set<Character> = Set(".,;:!?…—–")

    struct EnclosureShape {
        var openers: [Character]
        /// Closing marks at the end, innermost first.
        var closers: [Character]
        var hasCore: Bool
    }

    /// Leading opening marks and trailing closing marks (looking past trailing punctuation).
    static func enclosure(of token: String) -> EnclosureShape {
        let chars = Array(token)
        var start = 0
        var opened: [Character] = []
        while start < chars.count, openers[chars[start]] != nil {
            opened.append(chars[start])
            start += 1
        }
        var end = chars.count - 1
        var closed: [Character] = []
        while end >= start {
            let c = chars[end]
            if closers.contains(c) {
                closed.insert(c, at: 0)
            } else if !trailingPunctuation.contains(c) {
                break
            }
            end -= 1
        }
        // Anything that isn't a bracket, quote or punctuation counts: letters, numbers, emoji, symbols.
        let hasCore = end >= start && chars[start...end].contains {
            !$0.isWhitespace && openers[$0] == nil && !closers.contains($0) && !trailingPunctuation.contains($0)
        }
        return EnclosureShape(openers: opened, closers: closed, hasCore: hasCore)
    }

    /// The pair of marks drawn around a word inside an enclosure.
    public static func marks(for opener: Character) -> (open: String, close: String) {
        switch opener {
        case "\"": return ("“", "”")
        case "„": return ("„", "“")
        default: return (String(opener), String(openers[opener] ?? opener))
        }
    }

    /// The word without the enclosure's own marks, which are drawn separately around it.
    /// Other punctuation (commas, periods, apostrophes) stays.
    public static func focusText(_ text: String, enclosure: Character?) -> String {
        guard let enclosure, let closing = openers[enclosure] else { return text }
        var chars = Array(text)
        while let first = chars.first, openers[first] != nil, chars.count > 1 { chars.removeFirst() }
        // Strip the matching closer (and brackets) from the end, keeping trailing punctuation.
        let strippable: Set<Character> = Set(")]}”»›」』）】》〉\"").union([closing])
        var suffix: [Character] = []
        while let last = chars.last, chars.count > 1, strippable.contains(last) || trailingPunctuation.contains(last) {
            chars.removeLast()
            if !strippable.contains(last) { suffix.insert(last, at: 0) }
        }
        return String(chars + suffix)
    }
}

extension TextShaping {
    /// Marks that wrap a word without being part of it: brackets, quotes and dashes.
    private static let wrappers: Set<Character> = Set(openers.keys).union(closers)
        .union(["—", "–", "‒", "―", "⸺", "⸻", "'", "`", "´", "‚", "‛", "‟"])
    private static let sentencePunctuation: Set<Character> = Set(".,;:!?…")

    /// The word without the brackets, quotes and dashes around it, which slow down taking it in at a
    /// glance. Sentence punctuation and anything inside the word ("well-known", "don't") stay.
    public static func bareWord(_ text: String) -> String {
        let chars = Array(text)
        var start = 0
        while start < chars.count, wrappers.contains(chars[start]) || chars[start].isWhitespace { start += 1 }
        var end = chars.count
        var tail: [Character] = []
        while end > start {
            let c = chars[end - 1]
            if wrappers.contains(c) || c.isWhitespace {
                end -= 1
            } else if sentencePunctuation.contains(c) {
                tail.insert(c, at: 0)
                end -= 1
            } else {
                break
            }
        }
        // Nothing but marks ("—", "…"): show it as it is.
        guard end > start else { return text }
        return String(chars[start..<end] + tail)
    }
}

extension ReadingItem {
    /// What the focus view shows with bare words on: no brackets, quotes or dashes around it.
    public var bareText: String {
        TextShaping.bareWord(text)
    }

    /// What the focus view shows: the word without its enclosure's marks.
    public var focusText: String {
        TextShaping.focusText(text, enclosure: enclosure)
    }
}
