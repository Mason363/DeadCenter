import CoreGraphics
import Foundation

/// Recognizes running headers and footers, page numbers, and repeated decorations by
/// comparing a page with its neighbors.
enum RunningContent {
    /// Fraction of the page height at the top and bottom where running content lives.
    private static let band: CGFloat = 0.09

    private enum Edge { case top, bottom }

    /// The page's lines without running headers, footers, and page numbers.
    static func bodyLines(of page: PDFPageAnalysis, window: [PDFPageAnalysis], pageCount: Int) -> [TextLine] {
        let threshold = repetitionThreshold(pageCount: pageCount)
        let heights = page.lines.map(\.rect.height).sorted()
        let medianHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
        let neighborKeys = window.filter { $0.index != page.index }.map { Set(edgeKeys(of: $0).map { "\($0.edge)|\($0.key)" }) }

        return page.lines.enumerated().filter { i, line in
            guard let edge = edge(of: line, at: i, in: page) else { return true }
            if isPageNumber(line.text) { return false }
            guard let threshold, line.rect.height <= medianHeight * 1.5 + 0.5 else { return true }
            let key = "\(edge)|\(normalizedKey(line.text))"
            let repeats = 1 + neighborKeys.filter { $0.contains(key) }.count
            return repeats < threshold
        }.map(\.element)
    }

    /// The images worth showing: big enough, not repeated decorations, not a full-page scan behind real text.
    static func contentImages(of page: PDFPageAnalysis, window: [PDFPageAnalysis], pageCount: Int) -> [PDFImagePlacement] {
        let bounds = page.bounds
        let pageArea = bounds.width * bounds.height
        guard pageArea > 0 else { return [] }
        let threshold = repetitionThreshold(pageCount: pageCount)
        let textLength = page.lines.reduce(0) { $0 + $1.text.count }
        let neighborKeys = window.filter { $0.index != page.index }.map { Set($0.images.map(\.repeatKey)) }

        var accepted: [CGRect] = []
        for image in page.images {
            let rect = image.rect.intersection(bounds)
            guard !rect.isNull, rect.width >= 80, rect.height >= 80, rect.width * rect.height >= pageArea * 0.04 else { continue }
            if rect.width * rect.height >= pageArea * 0.7, textLength >= 200 { continue }
            if let threshold, 1 + neighborKeys.filter({ $0.contains(image.repeatKey) }).count >= threshold { continue }
            accepted.append(rect)
        }
        return merged(accepted).map { PDFImagePlacement(rect: $0, identity: "region") }
    }

    /// Unions overlapping or touching rectangles (tiled images that form one figure).
    private static func merged(_ rects: [CGRect]) -> [CGRect] {
        var result = rects
        var changed = true
        while changed {
            changed = false
            outer: for i in result.indices {
                for j in result.indices where j > i && result[i].insetBy(dx: -2, dy: -2).intersects(result[j]) {
                    result[i] = result[i].union(result[j])
                    result.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return result.sorted { $0.maxY > $1.maxY }
    }

    /// Pages a line must repeat on to count as running content, or nil if the document is too short to tell.
    private static func repetitionThreshold(pageCount: Int) -> Int? {
        switch pageCount {
        case ..<2: nil
        case 2: 2
        default: 3
        }
    }

    private static func edge(of line: TextLine, at index: Int, in page: PDFPageAnalysis) -> Edge? {
        let bounds = page.bounds
        guard bounds.height > 0 else { return nil }
        let top = bounds.maxY - bounds.height * band
        let bottom = bounds.minY + bounds.height * band
        if line.rect.midY >= top { return .top }
        if line.rect.midY <= bottom { return .bottom }
        // The first or last line of the page, a little further in, still counts.
        if index == 0, line.rect.midY >= bounds.maxY - bounds.height * band * 1.6 { return .top }
        if index == page.lines.count - 1, line.rect.midY <= bounds.minY + bounds.height * band * 1.6 { return .bottom }
        return nil
    }

    private static func edgeKeys(of page: PDFPageAnalysis) -> [(edge: Edge, key: String)] {
        page.lines.enumerated().compactMap { i, line in
            edge(of: line, at: i, in: page).map { ($0, normalizedKey(line.text)) }
        }
    }

    /// Lowercased with digits and roman numerals replaced, so "Chapter 3 · 41" matches "Chapter 3 · 42".
    static func normalizedKey(_ text: String) -> String {
        var out = ""
        var lastWasDigit = false
        for ch in text.lowercased() {
            if ch.isNumber {
                if !lastWasDigit { out.append("#") }
                lastWasDigit = true
            } else {
                lastWasDigit = false
                if ch.isWhitespace { if out.last != " " { out.append(" ") } } else { out.append(ch) }
            }
        }
        return out.split(separator: " ").map { isRomanNumeral($0) ? "#" : String($0) }.joined(separator: " ")
    }

    private static let pageNumberPattern = try! NSRegularExpression(
        pattern: #"^[\s\-–—|•·\[(]*(?:(?:page|p\.|pg\.?|seite|página|pagina)\s*)?(?:\d{1,4}|[ivxlcdm]{1,7})(?:\s*(?:of|/|von|de|sur|\|)\s*\d{1,4})?[\s\-–—|•·\])]*$|^第\s*\d+\s*页(?:\s*[/／共]\s*\d+\s*页?)?$"#,
        options: [.caseInsensitive])

    static func isPageNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 24 else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = pageNumberPattern.firstMatch(in: trimmed, range: range) else { return false }
        // Letters-only matches must be genuine roman numerals ("iv", not "mild").
        let letters = trimmed.lowercased().filter(\.isLetter)
        if !trimmed.contains(where: \.isNumber) { return isRomanNumeral(Substring(letters)) }
        return match.range.length > 0
    }

    private static func isRomanNumeral(_ token: Substring) -> Bool {
        guard !token.isEmpty, token.count <= 8 else { return false }
        return token.range(of: #"^m{0,3}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$"#, options: .regularExpression) != nil
    }
}
