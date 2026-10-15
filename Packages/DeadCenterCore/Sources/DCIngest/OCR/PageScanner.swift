import CoreGraphics
import Foundation
import ImageIO
import DCModel

/// One scanned page, ready for paragraph building.
struct ScannedPage {
    enum Edge { case top, bottom }

    /// Body lines in reading order. Figure labels, captions, display equations and page numbers are gone.
    var lines: [TextLine] = []
    var images: [LineParagraphBuilder.PlacedImage] = []
    /// Which lines sit at the top or bottom edge of the page's content.
    var edges: [Edge?] = []
    /// Lines that look like running headers or footers on this page alone.
    var running: Set<Int> = []
    /// Median height of the body lines.
    var bodyLineHeight: CGFloat = 0
    /// The page's top heading, when it opens with a clearly larger line.
    var heading: String?
}

/// The size of a page's body type, from OCR line boxes: their median height, and their median
/// width per character, which OCR reports more steadily than height.
private struct TypeMetrics {
    let bodyHeight: CGFloat
    let characterWidth: CGFloat

    init(_ lines: [TextLine]) {
        let heights = lines.map(\.rect.height).sorted()
        let body = heights.isEmpty ? 0 : heights[heights.count / 2]
        let widths = lines.filter { $0.text.count >= 20 && $0.rect.height > body * 0.7 && $0.rect.height < body * 1.4 }
            .map { $0.rect.width / CGFloat($0.text.count) }.sorted()
        bodyHeight = body
        characterWidth = widths.isEmpty ? 0 : widths[widths.count / 2]
    }

    /// Width per character relative to body text, for lines long enough to tell.
    func widthRatio(of line: TextLine) -> CGFloat? {
        guard characterWidth > 0, line.text.count >= 12 else { return nil }
        return line.rect.width / CGFloat(line.text.count) / characterWidth
    }
}

/// Reads one photographed or scanned page: straightens it, turns it upright, recognizes its
/// text, and separates figures, captions, display equations, margin notes, page numbers and
/// running heads from the body text.
final class PageScanner {
    private let corrector = PerspectiveCorrector()
    /// Stands in for a full-width figure during column ordering, so the page splits into bands around it.
    private static let figurePlaceholder = "\u{FFFC}"

    func scan(_ original: CGImage) -> ScannedPage {
        var image = corrector.straightened(original) ?? original
        var size = CGSize(width: image.width, height: image.height)
        var recognized = TextRecognizer.fragments(in: image, size: size)

        if let orientation = Self.orientation(of: recognized), let upright = corrector.rotated(image, orientation) {
            // Vision reads text on its side or upside down, but the layout needs an upright page.
            image = upright
            size = CGSize(width: image.width, height: image.height)
            recognized = TextRecognizer.fragments(in: image, size: size)
        } else if Self.isAlmostEmpty(recognized) {
            // Maybe the page is on its side and Vision couldn't read it that way.
            let turned = CGSize(width: size.height, height: size.width)
            var best = (score: Self.score(recognized), orientation: CGImagePropertyOrientation.up, fragments: recognized)
            for orientation in [CGImagePropertyOrientation.right, .left] {
                let candidate = TextRecognizer.fragments(in: image, size: turned, orientation: orientation)
                let score = Self.score(candidate)
                if score > best.score * 1.5 + 10 { best = (score, orientation, candidate) }
            }
            if best.orientation != .up, let upright = corrector.rotated(image, best.orientation),
               upright.width == Int(turned.width), upright.height == Int(turned.height) {
                image = upright
                size = turned
                recognized = best.fragments
            }
        }
        recognized = Self.rereadingMergedLines(Self.withoutEchoes(recognized), in: image, size: size)
        return layout(image, size: size, fragments: Self.withoutEchoes(recognized).map(\.line))
    }

    /// Vision sometimes reports part of a line a second time, less confidently, in a box that
    /// straddles the line; the echo is dropped.
    private static func withoutEchoes(_ fragments: [RecognizedText]) -> [RecognizedText] {
        let texts = fragments.map { $0.line.text.lowercased() }
        var echoes = Set<Int>()
        for (i, a) in fragments.enumerated() {
            let text = texts[i]
            let area = a.line.rect.width * a.line.rect.height
            guard text.count >= 3, area > 0 else { continue }
            let echoed = fragments.indices.contains { j in
                let b = fragments[j]
                guard j != i, !echoes.contains(j), b.confidence + 0.05 >= a.confidence,
                      texts[j].count > text.count || (texts[j].count == text.count && j < i),
                      texts[j].contains(text) else { return false }
                let overlap = a.line.rect.intersection(b.line.rect)
                return !overlap.isNull && overlap.width * overlap.height >= area * 0.2
            }
            if echoed { echoes.insert(i) }
        }
        return fragments.indices.filter { !echoes.contains($0) }.map { fragments[$0] }
    }

    /// Vision occasionally reads two lines of body text as one, in a box about two lines tall:
    /// garbled, or with both lines' words. Its type is no larger than the body's (a heading's
    /// characters grow as wide as they grow tall), so it shows as a tall box with narrow
    /// characters. Such a stretch is read again on its own, across its column.
    private static func rereadingMergedLines(_ fragments: [RecognizedText], in image: CGImage, size: CGSize) -> [RecognizedText] {
        let metrics = TypeMetrics(fragments.map(\.line))
        guard metrics.bodyHeight > 0 else { return fragments }
        var result: [RecognizedText] = []
        for (i, fragment) in fragments.enumerated() {
            let r = fragment.line.rect
            let height = r.height / metrics.bodyHeight
            let width = metrics.widthRatio(of: fragment.line)
            let merged = height >= 1.6 && width.map { $0 / height < 0.75 } == true
            let garbled = fragment.confidence <= 0.6 && height >= 1.8 && (width ?? 1) < 1.6
            guard merged || garbled else { result.append(fragment); continue }
            let around = fragments.indices.filter { $0 != i }.map { fragments[$0].line.rect }.filter { $0.maxX > r.minX && $0.minX < r.maxX }
            let above = around.filter { $0.midY > r.maxY }.min { $0.minY < $1.minY }
            let below = around.filter { $0.midY < r.minY }.max { $0.maxY < $1.maxY }
            let pad = metrics.bodyHeight * 0.5
            let minX = min(r.minX, above?.minX ?? r.minX, below?.minX ?? r.minX) - metrics.bodyHeight
            let maxX = max(r.maxX, above?.maxX ?? r.maxX, below?.maxX ?? r.maxX) + metrics.bodyHeight
            let minY = max(below?.maxY ?? r.minY - pad, r.minY - pad), maxY = min(above?.minY ?? r.maxY + pad, r.maxY + pad)
            let reread = Self.reread(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), of: image, size: size)
            let confidence = reread.reduce(Float(0)) { $0 + $1.confidence } / Float(max(reread.count, 1))
            let better = reread.count >= 2 && confidence >= 0.7 || !reread.isEmpty && confidence > fragment.confidence + 0.2
            if better {
                result += reread
            } else {
                result.append(fragment)
            }
        }
        return result
    }

    /// Vision now and then skips a line or two of plain text. Where unexplained ink sits in a gap
    /// between lines of a column wide enough to hold a line, the gap is read again on its own.
    private static func missedLines(in image: CGImage, size: CGSize, grid: InkGrid, fragments: [TextLine], bodyHeight: CGFloat) -> [TextLine] {
        guard bodyHeight > 0 else { return [] }
        var windows: [CGRect] = []
        for box in FigureDetector.unexplainedInk(in: grid, fragments: fragments, bodyHeight: bodyHeight) {
            // Text masking leaves only a sliver of a skipped line, so the sliver just marks the spot.
            guard box.width >= bodyHeight * 3, box.width >= box.height * 2.5, box.height <= bodyHeight * 6 else { continue }
            let column = fragments.map(\.rect).filter { line in
                let overlap = min(line.maxX, box.maxX) - max(line.minX, box.minX)
                return overlap >= min(box.width, line.width) * 0.5
            }
            let above = column.filter { $0.midY > box.maxY }.min { $0.minY < $1.minY }
            let below = column.filter { $0.midY < box.minY }.max { $0.maxY < $1.maxY }
            guard above != nil || below != nil else { continue }
            let pad = bodyHeight * 0.15
            let top = min(above.map { $0.minY + pad } ?? box.maxY + bodyHeight * 0.6, box.maxY + bodyHeight * 2)
            let bottom = max(below.map { $0.maxY - pad } ?? box.minY - bodyHeight * 0.6, box.minY - bodyHeight * 2)
            guard top - bottom >= bodyHeight * 0.8 else { continue }
            let minX = min(box.minX, above?.minX ?? box.minX, below?.minX ?? box.minX) - bodyHeight
            let maxX = max(box.maxX, above?.maxX ?? box.maxX, below?.maxX ?? box.maxX) + bodyHeight
            let window = CGRect(x: minX, y: bottom, width: maxX - minX, height: top - bottom)
            if !windows.contains(where: { $0.intersects(window) }) { windows.append(window) }
            if windows.count == 6 { break }
        }
        var found: [TextLine] = []
        for window in windows {
            for text in reread(window, of: image, size: size) where text.confidence >= 0.7 && text.line.text.filter(\.isLetter).count >= 2 {
                let repeated = fragments.contains { $0.rect.intersects(text.line.rect) && $0.text.lowercased().contains(text.line.text.lowercased()) }
                if !repeated { found.append(text.line) }
            }
        }
        return found
    }

    /// OCR of one region of the page, with the results placed back in page space.
    private static func reread(_ region: CGRect, of image: CGImage, size: CGSize) -> [RecognizedText] {
        let window = region.intersection(CGRect(origin: .zero, size: size))
        guard !window.isNull, window.width >= 8, window.height >= 8 else { return [] }
        let pixels = CGRect(x: window.minX, y: size.height - window.maxY, width: window.width, height: window.height).integral
        guard let crop = image.cropping(to: pixels) else { return [] }
        let origin = CGPoint(x: pixels.minX, y: size.height - pixels.maxY)
        return TextRecognizer.fragments(in: crop, size: CGSize(width: crop.width, height: crop.height)).map { found in
            var moved = found
            moved.line.rect = found.line.rect.offsetBy(dx: origin.x, dy: origin.y)
            return moved
        }
    }

    /// The EXIF orientation that turns the page upright, when most of its text runs sideways or upside down.
    private static func orientation(of fragments: [RecognizedText]) -> CGImagePropertyOrientation? {
        var votes: [CGImagePropertyOrientation: Int] = [:]
        var total = 0
        for fragment in fragments where fragment.confidence >= 0.5 {
            let letters = fragment.line.text.filter(\.isLetter).count
            guard letters >= 4 else { continue }
            let angle = atan2(fragment.direction.dy, fragment.direction.dx) * 180 / .pi
            let orientation: CGImagePropertyOrientation = switch angle {
            case -45...45: .up
            case 45...135: .right
            case -135 ... -45: .left
            default: .down
            }
            votes[orientation, default: 0] += letters
            total += letters
        }
        guard total >= 40, let (winner, count) = votes.max(by: { $0.value < $1.value }), winner != .up,
              count * 10 >= total * 6 else { return nil }
        return winner
    }

    /// Too little confident text to be an upright page of writing.
    private static func isAlmostEmpty(_ fragments: [RecognizedText]) -> Bool {
        let wordy = fragments.filter { $0.confidence >= 0.5 && $0.line.text.filter(\.isLetter).count >= 3 }
        return wordy.reduce(0) { $0 + $1.line.text.count } < 40
    }

    private static func score(_ fragments: [RecognizedText]) -> Double {
        fragments.reduce(0) { $0 + Double($1.confidence) * Double(min($1.line.text.filter(\.isLetter).count, 200)) }
    }

    // MARK: - Layout

    private func layout(_ image: CGImage, size: CGSize, fragments recognized: [TextLine]) -> ScannedPage {
        var fragments = recognized
        let bodyHeight = Self.median(fragments.map(\.rect.height))
        let content = fragments.reduce(CGRect.null) { $0.union($1.rect) }

        // Page numbers at the top and bottom edges.
        var pageNumbers: [CGRect] = []
        fragments.removeAll { line in
            guard Self.edge(of: line.rect, in: content) != nil, RunningContent.isPageNumber(line.text) else { return false }
            pageNumbers.append(line.rect)
            return true
        }

        let grid = InkGrid(image: image)
        if let grid { fragments += Self.missedLines(in: image, size: size, grid: grid, fragments: fragments, bodyHeight: bodyHeight) }
        let figures = grid.map { FigureDetector.figures(in: $0, fragments: fragments, bodyHeight: bodyHeight) } ?? []
        let absorbed = Set(figures.flatMap(\.absorbed))
        fragments = fragments.indices.filter { !absorbed.contains($0) }.map { fragments[$0] }
        fragments = Self.withoutMarginNotes(fragments)

        var images: [LineParagraphBuilder.PlacedImage] = []
        if let grid {
            var consumed = Set<Int>()
            for equation in EquationDetector.equations(in: fragments, grid: grid, bodyHeight: bodyHeight) {
                let others = fragments.indices.filter { !equation.fragments.contains($0) }.map { fragments[$0] }
                guard let asset = Self.crop(image, size: size, rect: equation.rect, avoiding: others, padding: 0, grid: grid,
                                            caption: nil, minimumSide: 12, lineArt: true) else { continue }
                images.append(.init(asset: asset, rect: equation.rect))
                consumed.formUnion(equation.fragments)
            }
            fragments = fragments.indices.filter { !consumed.contains($0) }.map { fragments[$0] }
        }

        // Reading order, with full-width figures splitting the columns into bands.
        let span = fragments.reduce(CGRect.null) { $0.union($1.rect) }
        let placeholders = figures.filter { !span.isNull && $0.rect.width >= span.width * 0.6 }.map {
            TextLine(text: Self.figurePlaceholder, rect: CGRect(x: $0.rect.minX, y: $0.rect.midY, width: $0.rect.width, height: 0))
        }
        var lines = OCRLayout.readingOrder(fragments + placeholders, pageWidth: size.width, scanned: true)
            .filter { $0.text != Self.figurePlaceholder }

        // Captions leave the text and go with their figures.
        var taken = Set<Int>()
        var captions: [String?] = []
        for figure in figures {
            let found = FigureDetector.caption(of: figure.rect, in: lines, taken: taken, bodyHeight: bodyHeight)
            captions.append(found.map { indices in indices.map { lines[$0].text }.reduce("") { TextNormalizer.join($0, $1) } })
            taken.formUnion(found ?? [])
        }
        let surrounding = lines
        lines = lines.indices.filter { !taken.contains($0) }.map { lines[$0] }

        if let grid {
            let padding = max(size.width * 0.01, 4)
            for (figure, caption) in zip(figures, captions) {
                guard let asset = Self.crop(image, size: size, rect: figure.rect, avoiding: surrounding, padding: padding,
                                            grid: grid, caption: caption, minimumSide: ImageData.minimumSide) else { continue }
                images.append(.init(asset: asset, rect: figure.rect))
            }
            // A page with hardly any text, such as a full-page photo or diagram, is shown whole.
            if figures.isEmpty, images.isEmpty, lines.reduce(0, { $0 + $1.text.count }) < 20, grid.inkFraction >= 0.03,
               let asset = Self.crop(image, size: size, rect: CGRect(origin: .zero, size: size), avoiding: [], padding: 0,
                                     grid: grid, caption: lines.isEmpty ? nil : lines.map(\.text).joined(separator: " "),
                                     minimumSide: ImageData.minimumSide) {
                images.append(.init(asset: asset, rect: CGRect(origin: .zero, size: size)))
                lines = []
            }
        }

        var page = ScannedPage(images: images)
        page.bodyLineHeight = Self.median(lines.map(\.rect.height))
        let lineBounds = lines.reduce(content) { $0.union($1.rect) }
        page.edges = lines.map { Self.edge(of: $0.rect, in: lineBounds) }
        page.running = Self.runningHeads(lines, edges: page.edges, pageNumbers: pageNumbers, bodyHeight: page.bodyLineHeight)
        page.heading = Self.heading(lines, skipping: page.running, bodyHeight: page.bodyLineHeight, content: lineBounds)
        page.lines = Self.evenedHeights(lines)
        return page
    }

    /// OCR boxes of body text vary in height from line to line. Lines set in body type get
    /// exactly the body height, so paragraph building doesn't see a change of font size.
    private static func evenedHeights(_ lines: [TextLine]) -> [TextLine] {
        let metrics = TypeMetrics(lines)
        let body = metrics.bodyHeight
        guard body > 0 else { return lines }
        return lines.map { line in
            let height = line.rect.height / body
            let width = metrics.widthRatio(of: line)
            let jitter = height > 0.7 && height < 1.4 && (width ?? 1) < 1.25
            let overgrown = height > 0.6 && height < 2 && width.map { $0 > 0.8 && $0 < 1.2 } == true
            guard jitter || overgrown else { return line }
            var evened = line
            evened.rect = CGRect(x: line.rect.minX, y: line.rect.midY - body / 2, width: line.rect.width, height: body)
            return evened
        }
    }

    // MARK: - Running heads

    /// Whether a line lies in the band along the top or bottom of the page's text.
    static func edge(of rect: CGRect, in content: CGRect) -> ScannedPage.Edge? {
        guard !content.isNull, content.height > 0 else { return nil }
        let band = content.height * 0.07
        if rect.midY >= content.maxY - band { return .top }
        if rect.midY <= content.minY + band { return .bottom }
        return nil
    }

    /// Lines that are running heads by their look alone: sharing a baseline with a page number,
    /// or a small or capitalized line set apart at the very top or bottom.
    private static func runningHeads(_ lines: [TextLine], edges: [ScannedPage.Edge?], pageNumbers: [CGRect], bodyHeight: CGFloat) -> Set<Int> {
        var running = Set<Int>()
        guard bodyHeight > 0 else { return running }
        for i in lines.indices where edges[i] != nil {
            let r = lines[i].rect
            if pageNumbers.contains(where: { min($0.maxY, r.maxY) - max($0.minY, r.minY) > min($0.height, r.height) * 0.5 }) {
                running.insert(i)
            }
        }
        func looksLikeRunningHead(_ line: TextLine, maxLength: Int) -> Bool {
            let letters = line.text.filter(\.isLetter)
            let capitalized = letters.count >= 4 && letters.filter(\.isUppercase).count * 10 >= letters.count * 9
            return line.text.count <= maxLength && line.rect.height <= bodyHeight * 1.15
                && (capitalized || line.rect.height <= bodyHeight * 0.85)
        }
        if let top = lines.indices.max(by: { lines[$0].rect.maxY < lines[$1].rect.maxY }), edges[top] == .top {
            let line = lines[top]
            let below = lines.indices.filter { $0 != top && lines[$0].rect.maxY < line.rect.minY }.map { lines[$0].rect.maxY }.max()
            if let below, line.rect.minY - below >= line.rect.height * 1.2, looksLikeRunningHead(line, maxLength: 90) { running.insert(top) }
        }
        if let bottom = lines.indices.min(by: { lines[$0].rect.minY < lines[$1].rect.minY }), edges[bottom] == .bottom {
            let line = lines[bottom]
            let above = lines.indices.filter { $0 != bottom && lines[$0].rect.minY > line.rect.maxY }.map { lines[$0].rect.minY }.min()
            if let above, above - line.rect.maxY >= line.rect.height * 1.2, looksLikeRunningHead(line, maxLength: 60) { running.insert(bottom) }
        }
        return running
    }

    /// The first clearly larger line (and its continuation) in the top part of the page.
    private static func heading(_ lines: [TextLine], skipping: Set<Int>, bodyHeight: CGFloat, content: CGRect) -> String? {
        guard bodyHeight > 0, !content.isNull else { return nil }
        let limit = content.maxY - content.height * 0.4
        for (i, line) in lines.enumerated() where !skipping.contains(i) && line.rect.maxY >= limit {
            guard line.rect.height >= bodyHeight * 1.5, line.text.filter(\.isLetter).count >= 2 else { continue }
            var text = line.text
            var last = line
            for next in lines.dropFirst(i + 1) {
                let ratio = next.rect.height / last.rect.height
                guard ratio > 0.8, ratio < 1.25, last.rect.minY - next.rect.maxY <= last.rect.height * 0.8 else { break }
                TextNormalizer.append(next.text, to: &text)
                last = next
            }
            return text.count <= 150 ? text : nil
        }
        return nil
    }

    // MARK: - Margin notes

    /// Drops notes set in a narrow outer column, clear of the main text block.
    static func withoutMarginNotes(_ lines: [TextLine]) -> [TextLine] {
        let span = lines.reduce(CGRect.null) { $0.union($1.rect) }
        guard !span.isNull, span.width > 0 else { return lines }
        let main = lines.filter { $0.rect.width >= span.width * 0.3 }
        guard main.count >= 6 else { return lines }
        let lefts = main.map(\.rect.minX).sorted(), rights = main.map(\.rect.maxX).sorted()
        let mainLeft = lefts[lefts.count / 20], mainRight = rights[rights.count * 19 / 20]
        let gap = span.width * 0.015
        return lines.filter { line in
            let r = line.rect
            guard r.width < span.width * 0.22, r.maxX < mainLeft - gap || r.minX > mainRight + gap else { return true }
            // A hanging section or line number belongs to the line beside it.
            let hanging = line.text.count <= 6 && line.text.allSatisfy { $0.isNumber || ".()".contains($0) }
            return hanging && main.contains { min($0.rect.maxY, r.maxY) - max($0.rect.minY, r.minY) > min($0.rect.height, r.height) * 0.5 }
        }
    }

    // MARK: - Images

    /// Crops a region of the page (growing it by `padding`, but not into the given lines) and encodes it:
    /// PNG for line art and flat-colored diagrams, JPEG for photos and anything photographed.
    private static func crop(_ image: CGImage, size: CGSize, rect: CGRect, avoiding lines: [TextLine], padding: CGFloat,
                             grid: InkGrid, caption: String?, minimumSide: Int, lineArt: Bool = false) -> ImageAsset? {
        var minX = rect.minX - padding, maxX = rect.maxX + padding
        var minY = rect.minY - padding, maxY = rect.maxY + padding
        for line in lines where !line.rect.intersects(rect) {
            let l = line.rect
            guard l.maxX > minX, l.minX < maxX, l.maxY > minY, l.minY < maxY else { continue }
            if l.maxY <= rect.minY { minY = max(minY, l.maxY) }
            else if l.minY >= rect.maxY { maxY = min(maxY, l.minY) }
            else if l.maxX <= rect.minX { minX = max(minX, l.maxX) }
            else if l.minX >= rect.maxX { maxX = min(maxX, l.minX) }
        }
        let region = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(CGRect(origin: .zero, size: size))
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        let pixels = CGRect(x: region.minX, y: size.height - region.maxY, width: region.width, height: region.height).integral
        guard let cropped = image.cropping(to: pixels) else { return nil }
        let data = lineArt || grid.isFlat(region) ? ImageData.pngData(cropped) : ImageData.jpegData(cropped, quality: 0.85)
        return data.flatMap { ImageData.asset($0, caption: caption, minimumSide: minimumSide) }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }
}
