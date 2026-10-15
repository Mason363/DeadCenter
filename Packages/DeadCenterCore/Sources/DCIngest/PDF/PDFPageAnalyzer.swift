import CoreGraphics
import Foundation
import PDFKit

/// What one page holds, gathered on the PDF worker queue.
struct PDFPageAnalysis: Sendable {
    var index: Int
    /// The page's crop box in page space (or, after OCR, the rendered page in points).
    var bounds: CGRect
    var lines: [TextLine]
    var images: [PDFImagePlacement]
    /// The page has no usable text layer but isn't blank.
    var needsOCR: Bool

    static func empty(_ index: Int) -> PDFPageAnalysis {
        PDFPageAnalysis(index: index, bounds: .zero, lines: [], images: [], needsOCR: false)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

enum PDFPageAnalyzer {
    static func analyze(_ page: PDFPage, index: Int) -> PDFPageAnalysis {
        let bounds = page.bounds(for: .cropBox)
        var lines: [TextLine] = []
        if let selection = page.selection(for: bounds) {
            for lineSelection in selection.selectionsByLine() {
                guard let raw = lineSelection.string else { continue }
                var text = withoutDotLeader(TextNormalizer.clean(raw))
                guard !text.isEmpty else { continue }
                // Cleaning drops soft hyphens; keep a line-final one as a hyphenation mark.
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("\u{AD}") { text += "\u{AD}" }
                let rect = lineSelection.bounds(for: page)
                guard rect.width > 0, rect.height > 0 else { continue }
                lines.append(TextLine(text: text, rect: rect))
            }
        }
        lines = mergingFragments(lines)
        let images = page.pageRef.map(PDFImageLocator.placements(on:)) ?? []
        let characters = lines.reduce(0) { $0 + $1.text.count }
        let pageArea = bounds.width * bounds.height
        let imageArea = images.reduce(CGFloat(0)) { $0 + $1.rect.intersection(bounds).area }
        let scanned = characters == 0 || (characters < 40 && imageArea > pageArea * 0.3)
        let needsOCR = scanned && !isBlank(page, bounds: bounds)
        return PDFPageAnalysis(index: index, bounds: bounds, lines: lines, images: images, needsOCR: needsOCR)
    }

    private static let dotLeader = try! NSRegularExpression(pattern: #"\s*(?:[.·…]\s?){4,}\s*[\divxlcdm]*\s*$"#, options: [.caseInsensitive])

    /// Table-of-contents lines: "Introduction ........ 12" → "Introduction".
    static func withoutDotLeader(_ text: String) -> String {
        guard text.contains("....") || text.contains(". . .") || text.contains("…") || text.contains("· · ·") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return dotLeader.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// PDFKit sometimes splits one printed line into several selections (separate text runs,
    /// wide sentence spacing). Consecutive fragments on the same baseline, close together, are one line.
    static func mergingFragments(_ lines: [TextLine]) -> [TextLine] {
        var merged: [TextLine] = []
        for line in lines {
            if let last = merged.last {
                let h = min(last.rect.height, line.rect.height)
                let sameBaseline = abs(last.rect.midY - line.rect.midY) < h * 0.35 && abs(last.rect.minY - line.rect.minY) < h * 0.5
                let gap = line.rect.minX - last.rect.maxX
                if sameBaseline, gap > -h, gap < h * 1.5 {
                    var text = last.text
                    let touching = gap < h * 0.12
                    if touching || TextNormalizer.isCJK(text.unicodeScalars.last ?? " ") || TextNormalizer.isCJK(line.text.unicodeScalars.first ?? " ") {
                        text += line.text
                    } else {
                        text += " " + line.text
                    }
                    merged[merged.count - 1] = TextLine(text: text, rect: last.rect.union(line.rect))
                    continue
                }
            }
            merged.append(line)
        }
        return merged
    }

    /// Renders a small grayscale thumbnail and checks for ink.
    private static func isBlank(_ page: PDFPage, bounds: CGRect) -> Bool {
        let width = 120
        let height = min(2000, max(1, Int(CGFloat(width) * bounds.height / max(bounds.width, 1))))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: CGFloat(width) / max(bounds.width, 1), y: CGFloat(height) / max(bounds.height, 1))
        page.draw(with: .cropBox, to: ctx)
        guard let data = ctx.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var inked = 0
        for i in 0..<(width * height) where pixels[i] < 200 { inked += 1 }
        return Double(inked) / Double(width * height) < 0.002
    }

    /// OCRs the page rendered at about 2×, returning lines in the rendered page's point space.
    static func recognizeText(on page: PDFPage) -> (lines: [TextLine], bounds: CGRect)? {
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = min(max(2, 2000 / longest), 4200 / longest)
        guard let ctx = ImageData.makeContext(width: Int(size.width * scale), height: Int(size.height * scale)) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage(), let lines = try? TextRecognizer.lines(in: image, size: size) else { return nil }
        return (lines, CGRect(origin: .zero, size: size))
    }

    /// Renders a region of the page (in page space) at 2× as PNG. Rendering rather than
    /// extracting the image keeps any vector labels drawn over it and avoids decoding PDF image formats.
    static func renderRegion(_ rect: CGRect, of page: PDFPage) -> Data? {
        let box = page.bounds(for: .cropBox)
        let clipped = rect.intersection(box)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        let target = clipped.applying(page.transform(for: .cropBox)).standardized
        var scale: CGFloat = 2
        let longest = max(target.width, target.height) * scale
        if longest > 2400 { scale *= 2400 / longest }
        guard let ctx = ImageData.makeContext(width: Int((target.width * scale).rounded()),
                                              height: Int((target.height * scale).rounded())) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -target.minX, y: -target.minY)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage().flatMap(ImageData.pngData)
    }
}
