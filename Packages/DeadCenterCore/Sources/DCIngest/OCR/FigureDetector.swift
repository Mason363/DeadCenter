import CoreGraphics
import Foundation

/// Finds figures on a scanned page (diagrams, photos, charts, ruled tables): regions of ink
/// that recognized text doesn't account for. Text inside a figure (labels, axis ticks) is
/// absorbed into it, and a caption next to it is recognized by its leading "Figure 2.3".
enum FigureDetector {
    struct Figure {
        /// Bounds in page space (origin bottom-left).
        var rect: CGRect
        /// Indices of the text fragments inside the figure, which leave the reading flow.
        var absorbed: Set<Int>
    }

    /// Bridges gaps of up to about twice this many cells within a figure.
    private static let closingRadius = 2

    static func figures(in grid: InkGrid, fragments: [TextLine], bodyHeight: CGFloat) -> [Figure] {
        let columns = grid.columns, rows = grid.rows
        guard columns > 10, rows > 10 else { return [] }
        let marginX = max(2, columns / 50), marginY = max(2, rows / 50)
        let total = columns * rows
        var boxes = unexplainedComponents(in: grid, fragments: fragments, bodyHeight: bodyHeight)
            .filter { $0.ink >= 8 && Double($0.area) >= Double(total) * 0.002 }
        boxes = merged(boxes, gap: max(2, columns / 60))

        var figures: [Figure] = []
        for box in boxes {
            let area = Double(box.area)
            guard Double(box.width) >= Double(columns) * 0.12, Double(box.height) >= Double(rows) * 0.05,
                  area >= Double(total) * 0.025, area <= Double(total) * 0.92,
                  Double(box.ink) >= area * 0.04
            else { continue }
            let touchesEdge = box.c0 <= marginX || box.c1 >= columns - 1 - marginX || box.r0 <= marginY || box.r1 >= rows - 1 - marginY
            let alongSide = Double(box.height) >= Double(rows) * 0.5 && Double(box.width) <= Double(columns) * 0.2
            let alongTop = Double(box.width) >= Double(columns) * 0.5 && Double(box.height) <= Double(rows) * 0.1
            if touchesEdge, alongSide || alongTop { continue }
            let rect = grid.rect(columns: box.c0...box.c1, rows: box.r0...box.r1)
            if let figure = absorbing(fragments, into: rect, bodyHeight: bodyHeight) { figures.append(figure) }
        }
        return mergedFigures(figures)
    }

    /// Bounds of the patches of ink that recognized text doesn't account for, in page space.
    static func unexplainedInk(in grid: InkGrid, fragments: [TextLine], bodyHeight: CGFloat) -> [CGRect] {
        guard grid.columns > 10, grid.rows > 10 else { return [] }
        return unexplainedComponents(in: grid, fragments: fragments, bodyHeight: bodyHeight).filter { $0.ink >= 8 }
            .sorted { $0.area > $1.area }
            .map { grid.rect(columns: $0.c0...$0.c1, rows: $0.r0...$0.r1) }
    }

    /// Components of the ink that isn't text, away from the page edges (shadows, the border of a
    /// photographed page), with small gaps closed.
    private static func unexplainedComponents(in grid: InkGrid, fragments: [TextLine], bodyHeight: CGFloat) -> [Box] {
        let columns = grid.columns, rows = grid.rows
        let marginX = max(2, columns / 50), marginY = max(2, rows / 50)
        var mask = grid.ink
        for r in 0..<rows {
            for c in 0..<columns where c < marginX || c >= columns - marginX || r < marginY || r >= rows - marginY {
                mask[r * columns + c] = false
            }
        }
        for line in fragments {
            // Glyphs barely leave their boxes; growing big boxes much would erase rules beside the text.
            let h = min(line.rect.height, bodyHeight > 0 ? bodyHeight * 1.5 : line.rect.height)
            guard let range = grid.cells(covering: line.rect.insetBy(dx: -0.3 * h, dy: -0.15 * h)) else { continue }
            for r in range.rows {
                for c in range.columns { mask[r * columns + c] = false }
            }
        }
        let closed = closing(mask, columns: columns, rows: rows, radius: closingRadius)
        return components(closed, raw: mask, columns: columns, rows: rows)
    }

    // MARK: - Text inside figures

    /// The figure with the text inside it absorbed, or nil if it's really a box of prose (a
    /// tinted sidebar) rather than a figure.
    private static func absorbing(_ fragments: [TextLine], into rect: CGRect, bodyHeight: CGFloat) -> Figure? {
        var bounds = rect
        var absorbed = Set<Int>()
        for _ in 0..<2 {
            for (i, line) in fragments.enumerated() where !absorbed.contains(i) {
                if mostlyInside(line.rect, bounds) || isNearbyLabel(line, of: bounds, bodyHeight: bodyHeight) {
                    absorbed.insert(i)
                }
            }
            bounds = absorbed.reduce(rect) { $0.union(fragments[$1].rect) }
        }
        let prose = absorbed.filter { isProse(fragments[$0], within: bounds) }
        if prose.count >= 3 { return nil }
        return Figure(rect: bounds, absorbed: absorbed)
    }

    private static func mostlyInside(_ line: CGRect, _ figure: CGRect) -> Bool {
        let overlap = line.intersection(figure)
        guard !overlap.isNull, line.width * line.height > 0 else { return false }
        return overlap.width * overlap.height >= line.width * line.height * 0.5
    }

    /// A short label hugging the figure's edge within its width: axis ticks, an axis title.
    private static func isNearbyLabel(_ line: TextLine, of figure: CGRect, bodyHeight: CGFloat) -> Bool {
        let r = line.rect
        guard line.text.count <= 24, r.height <= max(bodyHeight, 1) * 1.2, !isCaptionStart(line.text),
              r.minX >= figure.minX - r.height, r.maxX <= figure.maxX + r.height else { return false }
        let gap = max(r.minY - figure.maxY, figure.minY - r.maxY)
        guard gap <= r.height else { return false }
        let symbols = line.text.filter { !$0.isLetter && !$0.isWhitespace }.count
        let words = line.text.split(separator: " ").count
        return symbols * 2 >= line.text.count || (words <= 3 && !TextNormalizer.endsSentence(line.text))
    }

    /// A line of running text: several words filling much of the figure's width.
    private static func isProse(_ line: TextLine, within figure: CGRect) -> Bool {
        let words = line.text.split(separator: " ").filter { $0.filter(\.isLetter).count >= 3 }
        return words.count >= 4 && line.text.count >= 25 && line.rect.width >= figure.width * 0.35
    }

    // MARK: - Captions

    private static let captionPattern = try! NSRegularExpression(
        pattern: #"^(?:(?:fig(?:ure)?|table|tab|chart|diagram|graph|plate|photo(?:graph)?|image|illustration|map|exhibit|scheme|box|abbildung|abb|tabelle|figura|tableau|tabla)s?\.?\s*(?:[a-z]?\d+(?:[.\-–]\d+)*[a-z]?|(?-i:[IVXLC]+))\b|(?:source|sources|credit|credits|courtesy|photo|image|fig(?:ure)?|table|chart|diagram)\s*[:.—–]\s)"#,
        options: [.caseInsensitive])

    /// Whether a line opens a caption: "Figure 2.3", "Fig. 4", "Table IV", "Source:".
    static func isCaptionStart(_ text: String) -> Bool {
        captionPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The caption of a figure among the page's lines: a line just below it (or else just above
    /// it) that opens like "Figure 2.3", with the lines that continue it. Returns their indices.
    static func caption(of figure: CGRect, in lines: [TextLine], taken: Set<Int>, bodyHeight: CGFloat) -> [Int]? {
        let reach = max(bodyHeight, 8) * 2.5
        func beside(_ line: TextLine) -> Bool {
            let overlap = min(line.rect.maxX, figure.maxX) - max(line.rect.minX, figure.minX)
            return overlap >= line.rect.width * 0.5
        }
        func follows(_ next: TextLine, _ previous: TextLine) -> Bool {
            let h = previous.rect.height
            let ratio = next.rect.height / max(h, 1)
            let gap = previous.rect.minY - next.rect.maxY
            return gap > -0.3 * h && gap <= 0.9 * h && ratio > 0.75 && ratio < 1.33 && beside(next)
        }
        let candidates = lines.indices.filter { !taken.contains($0) && beside(lines[$0]) }

        // Below: the nearest line under the figure must open the caption.
        let below = candidates.filter { lines[$0].rect.maxY <= figure.minY + lines[$0].rect.height * 0.5 && lines[$0].rect.maxY >= figure.minY - reach }
        if let first = below.max(by: { lines[$0].rect.maxY < lines[$1].rect.maxY }), isCaptionStart(lines[first].text) {
            var block = [first]
            while block.count < 5, let next = candidates.filter({ !block.contains($0) && lines[$0].rect.maxY < lines[block.last!].rect.maxY })
                .max(by: { lines[$0].rect.maxY < lines[$1].rect.maxY }), follows(lines[next], lines[block.last!]) {
                block.append(next)
            }
            return block
        }

        // Above: a short block of lines over the figure whose first line opens the caption.
        let above = candidates.filter { lines[$0].rect.minY >= figure.maxY - lines[$0].rect.height * 0.5 && lines[$0].rect.minY <= figure.maxY + reach }
        guard let nearest = above.min(by: { lines[$0].rect.minY < lines[$1].rect.minY }) else { return nil }
        var block = [nearest]
        while block.count < 5, !isCaptionStart(lines[block[0]].text),
              let previous = candidates.filter({ !block.contains($0) && lines[$0].rect.minY > lines[block[0]].rect.minY })
                .min(by: { lines[$0].rect.minY < lines[$1].rect.minY }), follows(lines[block[0]], lines[previous]) {
            block.insert(previous, at: 0)
        }
        return isCaptionStart(lines[block[0]].text) ? block : nil
    }

    // MARK: - Grid operations

    private struct Box {
        var c0: Int, r0: Int, c1: Int, r1: Int
        /// Ink cells of the unclosed mask inside the component.
        var ink: Int

        var width: Int { c1 - c0 + 1 }
        var height: Int { r1 - r0 + 1 }
        var area: Int { width * height }

        func near(_ other: Box, gap: Int) -> Bool {
            c0 - gap <= other.c1 && other.c0 <= c1 + gap && r0 - gap <= other.r1 && other.r0 <= r1 + gap
        }

        func union(_ other: Box) -> Box {
            Box(c0: min(c0, other.c0), r0: min(r0, other.r0), c1: max(c1, other.c1), r1: max(r1, other.r1), ink: ink + other.ink)
        }
    }

    /// Dilation followed by erosion with a square of side `2 * radius + 1`.
    private static func closing(_ mask: [Bool], columns: Int, rows: Int, radius: Int) -> [Bool] {
        let dilated = morph(mask, columns: columns, rows: rows, radius: radius, dilate: true)
        return morph(dilated, columns: columns, rows: rows, radius: radius, dilate: false)
    }

    /// A separable max (dilate) or min (erode) filter. Erosion treats the outside as ink, so the
    /// closing never eats into figures at the border.
    private static func morph(_ mask: [Bool], columns: Int, rows: Int, radius: Int, dilate: Bool) -> [Bool] {
        var horizontal = [Bool](repeating: !dilate, count: mask.count)
        for r in 0..<rows {
            for c in 0..<columns {
                var value = !dilate
                for d in -radius...radius {
                    let x = c + d
                    let v = x >= 0 && x < columns ? mask[r * columns + x] : !dilate
                    if v == dilate { value = dilate; break }
                }
                horizontal[r * columns + c] = value
            }
        }
        var out = horizontal
        for r in 0..<rows {
            for c in 0..<columns {
                var value = !dilate
                for d in -radius...radius {
                    let y = r + d
                    let v = y >= 0 && y < rows ? horizontal[y * columns + c] : !dilate
                    if v == dilate { value = dilate; break }
                }
                out[r * columns + c] = value
            }
        }
        return out
    }

    /// Bounding boxes of 8-connected components of `mask`, counting `raw` ink inside each.
    private static func components(_ mask: [Bool], raw: [Bool], columns: Int, rows: Int) -> [Box] {
        var seen = [Bool](repeating: false, count: mask.count)
        var boxes: [Box] = []
        var stack: [Int] = []
        for start in mask.indices where mask[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var box = Box(c0: start % columns, r0: start / columns, c1: start % columns, r1: start / columns, ink: 0)
            while let i = stack.popLast() {
                let c = i % columns, r = i / columns
                box.c0 = min(box.c0, c); box.c1 = max(box.c1, c)
                box.r0 = min(box.r0, r); box.r1 = max(box.r1, r)
                if raw[i] { box.ink += 1 }
                for dr in -1...1 {
                    for dc in -1...1 where dr != 0 || dc != 0 {
                        let y = r + dr, x = c + dc
                        guard x >= 0, x < columns, y >= 0, y < rows else { continue }
                        let j = y * columns + x
                        if mask[j], !seen[j] {
                            seen[j] = true
                            stack.append(j)
                        }
                    }
                }
            }
            boxes.append(box)
        }
        return boxes
    }

    private static func merged(_ boxes: [Box], gap: Int) -> [Box] {
        var result = boxes
        var changed = true
        while changed {
            changed = false
            outer: for i in result.indices {
                for j in result.indices where j > i && result[i].near(result[j], gap: gap) {
                    result[i] = result[i].union(result[j])
                    result.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return result
    }

    private static func mergedFigures(_ figures: [Figure]) -> [Figure] {
        var result = figures
        var changed = true
        while changed {
            changed = false
            outer: for i in result.indices {
                for j in result.indices where j > i && result[i].rect.intersects(result[j].rect) {
                    result[i] = Figure(rect: result[i].rect.union(result[j].rect), absorbed: result[i].absorbed.union(result[j].absorbed))
                    result.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return result.sorted { $0.rect.maxY > $1.rect.maxY }
    }
}
