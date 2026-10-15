import CoreGraphics
import Foundation
import PDFKit
import DCModel

/// Streams a PDF page by page: text rebuilt into paragraphs, running headers and page numbers
/// removed, outline entries as chapters, figures rendered as images, scanned pages OCR'd.
enum PDFReader {
    /// Pages analyzed ahead of the one being emitted, for recognizing running headers.
    private static let lookahead = 3
    /// Pages kept behind the one being emitted.
    private static let lookbehind = 4

    static func read(url: URL, fallbackTitle: String, into emitter: BlockEmitter) throws {
        let worker = try PDFWorker(url: url)
        guard let info = try worker.run(timeout: 30, { DocumentInfo($0) }) else {
            throw IngestError.unreadable("the PDF took too long to open.")
        }
        emitter.title(info.title ?? fallbackTitle)
        guard info.pageCount > 0 else { throw IngestError.empty }
        let chapters = Dictionary(grouping: info.outline, by: \.pageIndex)

        var analyses: [Int: PDFPageAnalysis] = [:]
        var nextToAnalyze = 0
        var heights = HeightHistogram()
        var builder = LineParagraphBuilder()

        for index in 0..<info.pageCount {
            try Task.checkCancellation()
            while nextToAnalyze < info.pageCount, nextToAnalyze <= index + lookahead {
                let i = nextToAnalyze
                let analysis = try worker.run(timeout: 20) { document in
                    document.page(at: i).map { PDFPageAnalyzer.analyze($0, index: i) } ?? .empty(i)
                } ?? .empty(i)
                heights.add(analysis.lines)
                for line in analysis.lines { TextNormalizer.collectCompounds(in: line.text, into: &builder.compounds) }
                analyses[i] = analysis
                nextToAnalyze += 1
            }

            var page = analyses[index] ?? .empty(index)
            if page.needsOCR {
                let recognized = try worker.run(timeout: 60) { document in
                    document.page(at: index).flatMap(PDFPageAnalyzer.recognizeText(on:))
                } ?? nil
                let existing = page.lines.reduce(0) { $0 + $1.text.count }
                if let recognized, recognized.lines.reduce(0, { $0 + $1.text.count }) > existing {
                    page.lines = recognized.lines
                    page.bounds = recognized.bounds
                    page.images = []
                    heights.add(page.lines)
                }
                page.needsOCR = false
                analyses[index] = page
            }

            let window = ((index - lookbehind)...(index + lookahead)).compactMap { analyses[$0] }
            let regions = RunningContent.contentImages(of: page, window: window, pageCount: info.pageCount)
            let lines = RunningContent.bodyLines(of: page, window: window, pageCount: info.pageCount)
                .filter { line in !regions.contains { $0.rect.mostlyContains(line.rect) } }
            let images = try regions.compactMap { region -> LineParagraphBuilder.PlacedImage? in
                let data = try worker.run(timeout: 15) { document in
                    document.page(at: index).flatMap { PDFPageAnalyzer.renderRegion(region.rect, of: $0) }
                } ?? nil
                return data.flatMap { ImageData.asset($0) }.map { .init(asset: $0, rect: region.rect) }
            }

            builder.bodyLineHeight = heights.bodyHeight
            let pageChapters = (chapters[index] ?? []).map { LineParagraphBuilder.Chapter(title: $0.title, top: $0.top) }
            emitter.emit(builder.addPage(lines: lines, images: images, chapters: pageChapters))
            emitter.progress(Double(index + 1) / Double(info.pageCount))
            analyses.removeValue(forKey: index - lookbehind)
        }
        emitter.emit(builder.finish())
    }
}

/// Document-level facts gathered once when the PDF opens.
private struct DocumentInfo: Sendable {
    struct OutlineEntry: Sendable {
        var title: String
        var pageIndex: Int
        var top: CGFloat?
    }

    var pageCount: Int
    var title: String?
    var outline: [OutlineEntry]

    init(_ document: PDFDocument) {
        pageCount = document.pageCount
        title = Self.sensibleTitle(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        var entries: [OutlineEntry] = []
        if let root = document.outlineRoot {
            // CoreGraphics reports a destination rectangle for /FitR and /XYZ destinations where
            // PDFKit only has a point for /XYZ; it fills in positions PDFKit leaves unspecified.
            let geometry = document.documentRef?.outline as? [String: Any]
            Self.collect(root, geometry: geometry, depth: 0, document: document, into: &entries)
        }
        outline = entries
    }

    private static func collect(_ node: PDFOutline, geometry: [String: Any]?, depth: Int, document: PDFDocument,
                                into entries: inout [OutlineEntry]) {
        guard depth < 3, entries.count < 3000 else { return }
        let geometryChildren = (geometry?[kCGPDFOutlineChildren as String] as? [[String: Any]])
            .flatMap { $0.count == node.numberOfChildren ? $0 : nil }
        for i in 0..<node.numberOfChildren {
            guard let child = node.child(at: i) else { continue }
            let childGeometry = geometryChildren?[i]
            let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
            if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
               let destination, let page = destination.page {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound, pageIndex >= 0 {
                    let box = page.bounds(for: .cropBox)
                    var y = destination.point.y
                    if y == kPDFDestinationUnspecifiedValue || !y.isFinite,
                       let dict = childGeometry?[kCGPDFOutlineDestinationRect as String] as? NSDictionary,
                       let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) {
                        y = rect.maxY
                    }
                    let top: CGFloat? = (y == kPDFDestinationUnspecifiedValue || !y.isFinite || y >= box.maxY - 2 || y <= box.minY) ? nil : y
                    entries.append(OutlineEntry(title: label, pageIndex: pageIndex, top: top))
                }
            }
            collect(child, geometry: childGeometry, depth: depth + 1, document: document, into: &entries)
        }
    }

    /// Metadata titles are often junk ("Microsoft Word - draft3.doc", "Untitled", "Document1").
    static func sensibleTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), title.count >= 2 else { return nil }
        for prefix in ["Microsoft Word - ", "Microsoft PowerPoint - ", "Microsoft Excel - "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        let lower = title.lowercased()
        let junk = ["untitled", "untitled document", "document", "title", "pdf", "none", "unknown", "slide 1", "no title", "(anonymous)"]
        if junk.contains(lower) || title.count > 200 { return nil }
        if lower.range(of: #"\.(docx?|pdf|indd|qxp|qxd|rtf|txt|pages|tex|dvi|ps|odt|pptx?|xlsx?|key|html?)$"#, options: .regularExpression) != nil { return nil }
        if lower.range(of: #"^(document|doc|untitled|microsoft word)\s*\d*$"#, options: .regularExpression) != nil { return nil }
        if title.contains("\\") || title.hasPrefix("/") || title.range(of: #"^[\d\s_\-.]+$"#, options: .regularExpression) != nil { return nil }
        return title
    }
}

/// Character-weighted distribution of line heights.
private struct HeightHistogram {
    private var weights: [Int: Int] = [:]

    mutating func add(_ lines: [TextLine]) {
        for line in lines {
            weights[Int((line.rect.height * 2).rounded()), default: 0] += line.text.count
        }
    }

    /// The most common line height, weighted by characters: body text.
    var bodyHeight: CGFloat {
        guard let mode = weights.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return 0 }
        return CGFloat(mode.key) / 2
    }
}

private extension CGRect {
    /// Whether most of `other` lies inside this rectangle.
    func mostlyContains(_ other: CGRect) -> Bool {
        let overlap = intersection(other)
        guard !overlap.isNull, other.width * other.height > 0 else { return false }
        return overlap.width * overlap.height >= other.width * other.height * 0.7
    }
}
