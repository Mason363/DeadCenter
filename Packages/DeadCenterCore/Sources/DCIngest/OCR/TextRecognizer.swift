import CoreGraphics
import Foundation
import Vision

/// A line of text with its bounds, in a bottom-left-origin coordinate space (PDF page space,
/// or points of a rendered image).
struct TextLine: Sendable, Equatable {
    var text: String
    var rect: CGRect
}

/// A fragment of a line found by OCR, with Vision's confidence in it (0…1) and the direction
/// its text runs in (along the top edge, left to right as read).
struct RecognizedText: Sendable {
    var line: TextLine
    var confidence: Float
    var direction: CGVector
}

/// On-device OCR with Vision.
enum TextRecognizer {
    /// Recognizes text in `image` and returns lines in reading order, in a space of `size`
    /// (origin bottom-left) — typically the image's size in points.
    static func lines(in image: CGImage, size: CGSize) throws -> [TextLine] {
        OCRLayout.readingOrder(fragments(in: image, size: size).map(\.line), pageWidth: size.width)
    }

    /// The fragments Vision recognizes, unordered and unmerged. `orientation` turns the image
    /// upright first; `size` is the upright image's size.
    static func fragments(in image: CGImage, size: CGSize, orientation: CGImagePropertyOrientation = .up) -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if let supported = try? request.supportedRecognitionLanguages() {
            request.recognitionLanguages = preferredLanguages(supported: supported)
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.2 else { return nil }
            let text = TextNormalizer.clean(candidate.string)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                              width: box.width * size.width, height: box.height * size.height)
            let direction = CGVector(dx: (observation.topRight.x - observation.topLeft.x) * size.width,
                                     dy: (observation.topRight.y - observation.topLeft.y) * size.height)
            return RecognizedText(line: TextLine(text: text, rect: rect), confidence: candidate.confidence, direction: direction)
        }
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
    /// - Parameter scanned: the fragments come from a photo or scan of a printed page. A gutter
    ///   that a few narrow lines cross (a full-width paragraph's short last line, a caption) is
    ///   still a gutter, and those lines split the page into bands like titles do. Fragments are
    ///   merged into a row only side by side, since the boxes of neighboring lines can overlap.
    static func readingOrder(_ fragments: [TextLine], pageWidth: CGFloat, scanned: Bool = false) -> [TextLine] {
        guard !fragments.isEmpty else { return [] }
        return order(fragments, width: pageWidth, depth: 0, scanned: scanned)
    }

    private static func order(_ lines: [TextLine], width: CGFloat, depth: Int, scanned: Bool) -> [TextLine] {
        guard depth < 3, lines.count >= 6, let gutter = findGutter(lines, scanned: scanned) else {
            return mergeRows(lines.sorted { $0.rect.midY > $1.rect.midY }, scanned: scanned)
        }
        // Lines crossing the gutter (titles, full-width figures' captions) split the page into bands.
        var result: [TextLine] = []
        var left: [TextLine] = []
        var right: [TextLine] = []
        func flushColumns() {
            result += order(left, width: width, depth: depth + 1, scanned: scanned)
            result += order(right, width: width, depth: depth + 1, scanned: scanned)
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

    /// An x position, away from the edges, that no narrow line crosses (for scans, hardly any) and with text on both sides.
    private static func findGutter(_ lines: [TextLine], scanned: Bool) -> CGFloat? {
        let minX = lines.map(\.rect.minX).min() ?? 0
        let maxX = lines.map(\.rect.maxX).max() ?? 0
        let span = maxX - minX
        guard span > 0 else { return nil }
        let narrow = lines.filter { $0.rect.width < span * 0.6 }
        guard narrow.count >= 4 else { return nil }
        let bins = 200
        let allowedCrossings = scanned ? max(1, narrow.count / 12) : 0
        var covered = [Int](repeating: 0, count: bins)
        for line in narrow {
            let a = Int(((line.rect.minX - minX) / span * CGFloat(bins)).rounded(.down))
            let b = Int(((line.rect.maxX - minX) / span * CGFloat(bins)).rounded(.up))
            for i in max(0, a)..<min(bins, max(b, a + 1)) { covered[i] += 1 }
        }
        var best: (start: Int, length: Int)?
        var runStart: Int?
        for i in 0...bins {
            let free = i < bins && covered[i] <= allowedCrossings && i > bins / 5 && i < bins * 4 / 5
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
    private static func mergeRows(_ sorted: [TextLine], scanned: Bool) -> [TextLine] {
        var rows: [[TextLine]] = []
        for line in sorted {
            if let last = rows.last?.first {
                let overlap = min(last.rect.maxY, line.rect.maxY) - max(last.rect.minY, line.rect.minY)
                let sideBySide = !scanned || rows[rows.count - 1].allSatisfy { other in
                    let low = min(other.rect.height, line.rect.height), high = max(other.rect.height, line.rect.height)
                    return min(other.rect.maxX, line.rect.maxX) - max(other.rect.minX, line.rect.minX) <= low * 0.5 && high <= low * 2.5
                }
                if overlap > min(last.rect.height, line.rect.height) * 0.5, sideBySide {
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
