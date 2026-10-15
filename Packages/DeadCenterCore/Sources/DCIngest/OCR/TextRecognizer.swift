import CoreGraphics
import Foundation
import Vision

/// A line of text with its bounds, in a bottom-left-origin coordinate space (PDF page space,
/// or points of a rendered image).
struct TextLine: Sendable, Equatable {
    var text: String
    var rect: CGRect
}

/// On-device OCR with Vision.
enum TextRecognizer {
    /// Recognizes text in `image` and returns lines in reading order, in a space of `size`
    /// (origin bottom-left) — typically the image's size in points.
    static func lines(in image: CGImage, size: CGSize) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if let supported = try? request.supportedRecognitionLanguages() {
            request.recognitionLanguages = preferredLanguages(supported: supported)
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        let fragments: [TextLine] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.2 else { return nil }
            let text = TextNormalizer.clean(candidate.string)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                              width: box.width * size.width, height: box.height * size.height)
            return TextLine(text: text, rect: rect)
        }
        return OCRLayout.readingOrder(fragments, pageWidth: size.width)
    }

    /// The user's languages first, then the scripts Dead Center readers commonly need.
    private static func preferredLanguages(supported: [String]) -> [String] {
        var wanted: [String] = []
        for identifier in Locale.preferredLanguages {
            let locale = Locale(identifier: identifier)
            let language = locale.language.languageCode?.identifier ?? ""
            let script = locale.language.script?.identifier
            let match = supported.first { $0 == identifier }
                ?? supported.first { candidate in
                    let parts = candidate.split(separator: "-")
                    guard parts.first.map(String.init) == language else { return false }
                    if language == "zh" { return parts.count > 1 && String(parts[1]) == (script ?? "Hans") }
                    return true
                }
            if let match, !wanted.contains(match) { wanted.append(match) }
        }
        for fallback in ["en-US", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR"] where supported.contains(fallback) && !wanted.contains(fallback) {
            wanted.append(fallback)
        }
        return wanted
    }
}

/// Puts OCR fragments into reading order: columns left to right (split at clear vertical
/// gutters), top to bottom within a column, and fragments on the same baseline merged.
enum OCRLayout {
    static func readingOrder(_ fragments: [TextLine], pageWidth: CGFloat) -> [TextLine] {
        guard !fragments.isEmpty else { return [] }
        return order(fragments, width: pageWidth, depth: 0)
    }

    private static func order(_ lines: [TextLine], width: CGFloat, depth: Int) -> [TextLine] {
        guard depth < 3, lines.count >= 6, let gutter = findGutter(lines) else {
            return mergeRows(lines.sorted { $0.rect.midY > $1.rect.midY })
        }
        // Lines crossing the gutter (titles, full-width figures' captions) split the page into bands.
        var result: [TextLine] = []
        var left: [TextLine] = []
        var right: [TextLine] = []
        func flushColumns() {
            result += order(left, width: width, depth: depth + 1)
            result += order(right, width: width, depth: depth + 1)
            left.removeAll()
            right.removeAll()
        }
        for line in lines.sorted(by: { $0.rect.maxY > $1.rect.maxY }) {
            if line.rect.maxX <= gutter { left.append(line) }
            else if line.rect.minX >= gutter { right.append(line) }
            else {
                flushColumns()
                result.append(line)
            }
        }
        flushColumns()
        return result
    }

    /// An x position, away from the edges, that no narrow line crosses and with text on both sides.
    private static func findGutter(_ lines: [TextLine]) -> CGFloat? {
        let minX = lines.map(\.rect.minX).min() ?? 0
        let maxX = lines.map(\.rect.maxX).max() ?? 0
        let span = maxX - minX
        guard span > 0 else { return nil }
        let narrow = lines.filter { $0.rect.width < span * 0.6 }
        guard narrow.count >= 4 else { return nil }
        let bins = 200
        var covered = [Bool](repeating: false, count: bins)
        for line in narrow {
            let a = Int(((line.rect.minX - minX) / span * CGFloat(bins)).rounded(.down))
            let b = Int(((line.rect.maxX - minX) / span * CGFloat(bins)).rounded(.up))
            for i in max(0, a)..<min(bins, max(b, a + 1)) { covered[i] = true }
        }
        var best: (start: Int, length: Int)?
        var runStart: Int?
        for i in 0...bins {
            let free = i < bins && !covered[i] && i > bins / 5 && i < bins * 4 / 5
            if free { runStart = runStart ?? i }
            else if let start = runStart {
                if i - start > (best?.length ?? 0) { best = (start, i - start) }
                runStart = nil
            }
        }
        guard let gap = best, gap.length >= 2 else { return nil }
        let x = minX + span * (CGFloat(gap.start) + CGFloat(gap.length) / 2) / CGFloat(bins)
        let leftCount = narrow.filter { $0.rect.maxX <= x }.count
        let rightCount = narrow.filter { $0.rect.minX >= x }.count
        guard leftCount >= 2, rightCount >= 2, min(leftCount, rightCount) * 5 >= narrow.count else { return nil }
        return x
    }

    /// Merges fragments that share a baseline (sorted top to bottom) into single lines.
    private static func mergeRows(_ sorted: [TextLine]) -> [TextLine] {
        var rows: [[TextLine]] = []
        for line in sorted {
            if let last = rows.last?.first {
                let overlap = min(last.rect.maxY, line.rect.maxY) - max(last.rect.minY, line.rect.minY)
                if overlap > min(last.rect.height, line.rect.height) * 0.5 {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows.map { row in
            let ordered = row.sorted { $0.rect.minX < $1.rect.minX }
            var text = ordered[0].text
            var rect = ordered[0].rect
            for fragment in ordered.dropFirst() {
                TextNormalizer.append(fragment.text, to: &text)
                rect = rect.union(fragment.rect)
            }
            return TextLine(text: text, rect: rect)
        }
    }
}
