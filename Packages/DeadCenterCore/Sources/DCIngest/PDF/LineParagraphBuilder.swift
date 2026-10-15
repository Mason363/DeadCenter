import CoreGraphics
import Foundation
import DCModel

/// Rebuilds paragraphs from positioned lines (PDF text or OCR), page after page.
///
/// A new paragraph starts at extra vertical space, an indented first line, a change of font
/// size, a list marker, or after a short line that ends a sentence. An unfinished paragraph
/// at the bottom of a page continues on the next one unless the page break also looks like
/// a paragraph break. Images are held until the paragraph they interrupt has finished.
struct LineParagraphBuilder {
    /// Typical body text line height, for recognizing headings. Set by the caller as it learns the document.
    var bodyLineHeight: CGFloat = 0
    /// Hyphenated words seen in the document, so line-end hyphens in real compounds are kept.
    var compounds: Set<String> = []

    struct PlacedImage {
        var asset: ImageAsset
        var rect: CGRect
    }

    struct Chapter {
        var title: String
        /// Vertical position of the destination on the page, if known.
        var top: CGFloat?
    }

    private struct OpenParagraph {
        var text: String
        var lineCount: Int
        var heightSum: CGFloat
        var last: TextLine
        var lastIsShort: Bool
        var lastIsVeryShort: Bool
        /// Left edge of the first line, and whether that line began with a list marker
        /// (continuation lines of a list item hang indented under it).
        var firstLineX: CGFloat
        var isListItem: Bool
        var fromPreviousPage = false

        var averageHeight: CGFloat { heightSum / CGFloat(max(lineCount, 1)) }
    }

    private var open: OpenParagraph?
    private var dueImages: [ImageAsset] = []
    private var output: [Block] = []

    /// Adds one page and returns the blocks completed so far.
    mutating func addPage(lines: [TextLine], images: [PlacedImage] = [], chapters: [Chapter] = []) -> [Block] {
        output = []
        let metrics = PageMetrics(lines)
        var imageAnchors = images.map { (anchor(for: $0.rect, in: lines), $0.asset) }
        var chapterAnchors = chapters.map { (anchor(forTop: $0.top, in: lines, metrics: metrics), $0.title) }

        for (i, line) in lines.enumerated() {
            if chapterAnchors.contains(where: { $0.0 == i }) {
                finishParagraph()
                output += chapterAnchors.filter { $0.0 == i }.map { .chapter($0.1) }
                chapterAnchors.removeAll { $0.0 == i }
            }
            let arriving = imageAnchors.filter { $0.0 == i }.map(\.1)
            imageAnchors.removeAll { $0.0 == i }
            dueImages += arriving
            if open == nil { emitDueImages() }

            let shortness = metrics.shortness(ofLineAt: i, in: lines)
            if let current = open, !startsParagraph(line, at: i, in: lines, after: current, metrics: metrics) {
                var updated = current
                TextNormalizer.append(line.text, to: &updated.text, compounds: compounds)
                updated.lineCount += 1
                updated.heightSum += line.rect.height
                updated.last = line
                updated.lastIsShort = shortness.short
                updated.lastIsVeryShort = shortness.veryShort
                updated.fromPreviousPage = false
                open = updated
            } else {
                finishParagraph()
                open = OpenParagraph(text: line.text, lineCount: 1, heightSum: line.rect.height, last: line,
                                     lastIsShort: shortness.short, lastIsVeryShort: shortness.veryShort,
                                     firstLineX: line.rect.minX, isListItem: TextNormalizer.listMarker(in: line.text) != nil)
            }
        }

        if !chapterAnchors.isEmpty {
            finishParagraph()
            output += chapterAnchors.map { .chapter($0.1) }
        }
        dueImages += imageAnchors.map(\.1)
        if open == nil { emitDueImages() }
        open?.fromPreviousPage = true
        return output
    }

    /// Ends the document, returning the last paragraph and any images still waiting.
    mutating func finish() -> [Block] {
        output = []
        finishParagraph()
        emitDueImages()
        return output
    }

    // MARK: - Decisions

    private func startsParagraph(_ line: TextLine, at index: Int, in lines: [TextLine], after current: OpenParagraph,
                                 metrics: PageMetrics) -> Bool {
        let previous = current.last
        let h = max(min(previous.rect.height, line.rect.height), 1)
        if let marker = TextNormalizer.listMarker(in: line.text) {
            // Bullets always start an item; "(1)" or "2." can also be a wrapped line's first word.
            if marker.isSymbol || current.isListItem || current.lastIsShort || TextNormalizer.endsClause(previous.text) { return true }
        }
        let ratio = line.rect.height / max(previous.rect.height, 1)
        if ratio > 1.3 || ratio < 0.77 { return true }
        let startsCapitalized = line.text.unicodeScalars.first.map { $0.properties.isUppercase || $0.properties.numericType != nil } ?? false
        let next = index + 1 < lines.count ? lines[index + 1] : nil
        // A first line indented past the line after it starts a paragraph, unless it's the
        // hanging continuation of a list item.
        let indentedFirstLine: Bool = {
            guard let next, TextNormalizer.listMarker(in: next.text) == nil, next.rect.midY < line.rect.midY,
                  line.rect.minX - next.rect.minX > 0.8 * h else { return false }
            return !(current.isListItem && line.rect.minX > current.firstLineX + 0.3 * h)
        }()

        if current.fromPreviousPage {
            guard TextNormalizer.endsSentence(previous.text) else {
                return current.lastIsShort && startsCapitalized && current.lineCount == 1
            }
            return current.lastIsShort || indentedFirstLine
        }

        let drop = previous.rect.midY - line.rect.midY
        if drop < -0.5 * h || line.rect.minX > previous.rect.maxX {
            // Moved up or sideways: the next column. Continue mid-sentence, otherwise break.
            return TextNormalizer.endsSentence(previous.text) && current.lastIsShort
        }
        if drop > metrics.leading * 1.45 + 0.1 * h { return true }
        if indentedFirstLine, line.rect.minX - previous.rect.minX > 0.8 * h { return true }
        if TextNormalizer.endsSentence(previous.text), let next, metrics.shortness(ofLineAt: index, in: lines).veryShort,
           metrics.shortness(ofLineAt: index + 1, in: lines).veryShort, next.rect.midY < line.rect.midY {
            // A run of short lines after a finished sentence: an address, a list, verse.
            return true
        }
        if current.lastIsShort {
            if TextNormalizer.endsSentence(previous.text) { return true }
            let startsCJK = line.text.unicodeScalars.first.map(TextNormalizer.isCJK) ?? false
            if current.lastIsVeryShort, startsCapitalized || startsCJK, !previous.text.hasSuffix(","), !previous.text.hasSuffix("-") { return true }
        }
        return false
    }

    private func anchor(for rect: CGRect, in lines: [TextLine]) -> Int {
        let below = lines.indices.filter { lines[$0].rect.midY < rect.midY }
        let sameColumn = below.first { lines[$0].rect.maxX > rect.minX && lines[$0].rect.minX < rect.maxX }
        return sameColumn ?? below.first ?? lines.count
    }

    private func anchor(forTop top: CGFloat?, in lines: [TextLine], metrics: PageMetrics) -> Int {
        guard let top else { return 0 }
        return lines.firstIndex { $0.rect.maxY <= top + metrics.medianHeight * 0.6 } ?? lines.count
    }

    // MARK: - Output

    private mutating func finishParagraph() {
        guard let paragraph = open else { return }
        open = nil
        let text = paragraph.text
        if bodyLineHeight > 0, paragraph.lineCount <= 3, text.count <= 200, !text.hasSuffix("."),
           paragraph.averageHeight >= bodyLineHeight * 1.3 {
            let ratio = paragraph.averageHeight / bodyLineHeight
            output.append(.heading(text, level: ratio >= 1.9 ? 1 : ratio >= 1.5 ? 2 : 3))
        } else {
            output.append(.paragraph(text))
        }
        emitDueImages()
    }

    private mutating func emitDueImages() {
        output += dueImages.map(Block.image)
        dueImages.removeAll()
    }
}

/// Line spacing and line-length measurements for one page.
private struct PageMetrics {
    let medianHeight: CGFloat
    let leading: CGFloat

    init(_ lines: [TextLine]) {
        let heights = lines.map(\.rect.height).sorted()
        medianHeight = heights.isEmpty ? 12 : max(heights[heights.count / 2], 1)
        var spacings: [CGFloat] = []
        for (a, b) in zip(lines, lines.dropFirst()) where a.rect.maxX > b.rect.minX && a.rect.minX < b.rect.maxX {
            let spacing = a.rect.midY - b.rect.midY
            if spacing > medianHeight * 0.5, spacing < medianHeight * 3 { spacings.append(spacing) }
        }
        spacings.sort()
        leading = spacings.isEmpty ? medianHeight * 1.2 : spacings[spacings.count / 2]
    }

    /// Whether a line ends well short of its neighbors' right edge (a paragraph's last line, a
    /// heading, a list item), and whether it fills less than 60% of its column (addresses, verse).
    func shortness(ofLineAt i: Int, in lines: [TextLine]) -> (short: Bool, veryShort: Bool) {
        let line = lines[i]
        var right: CGFloat = 0
        for j in [i - 2, i - 1, i + 1, i + 2] where lines.indices.contains(j) {
            let other = lines[j]
            guard other.rect.maxX > line.rect.minX, other.rect.minX < line.rect.maxX,
                  abs(other.rect.midY - line.rect.midY) < leading * 4 else { continue }
            right = max(right, other.rect.maxX)
        }
        let short = right > line.rect.maxX && right - line.rect.maxX > max(2.5 * line.rect.height, 0.1 * (right - line.rect.minX))

        // The column's right edge: the 90th percentile of lines sharing this line's horizontal span.
        let column = lines.filter { $0.rect.maxX > line.rect.minX && $0.rect.minX < line.rect.maxX }.map(\.rect.maxX).sorted()
        let columnRight = column.isEmpty ? line.rect.maxX : column[min(column.count - 1, column.count * 9 / 10)]
        let veryShort = columnRight - line.rect.maxX > 0.4 * (columnRight - line.rect.minX)
        return (short || veryShort, veryShort)
    }
}
