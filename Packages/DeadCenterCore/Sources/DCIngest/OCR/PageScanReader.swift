import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Photos and scans of printed pages (textbooks, papers), read page by page: each page is
/// straightened and OCR'd, figures and display equations become images in reading order,
/// captions go with their figures, and page numbers and running heads are dropped.
enum PageScanReader {
    /// Pages scanned ahead of the one being emitted, so running heads can be matched across
    /// pages (including heads that alternate between left and right pages).
    private static let lookahead = 2
    private static let lookbehind = 2
    /// Longest side a page is decoded at.
    static let maximumPixelSize = 3000

    static func read(_ source: ScanSource, into emitter: BlockEmitter) async throws {
        switch source {
        case .images(let images):
            try read(pages(images), title: nil, into: emitter)
        case .file(let url):
            try await readFile(url, into: emitter)
        }
    }

    // MARK: - Sources

    /// Pages decoded one at a time when the scan reaches them.
    struct Pages {
        var count: Int
        var image: (Int) throws -> CGImage?
    }

    private static func readFile(_ url: URL, into emitter: BlockEmitter) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw IngestError.unreadable("the file couldn't be found.")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw IngestError.unreadable("Dead Center doesn't have permission to open it.")
        }
        let format = DocumentFormat.declared(by: url) ?? DocumentRouter.sniffedFormat(of: url)
        let name = url.deletingPathExtension().lastPathComponent
        let title = isGenericName(name) ? nil : name
        switch format {
        case .pdf:
            try readPDF(url, title: title, into: emitter)
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                throw IngestError.unreadable("the image couldn't be decoded.")
            }
            try read(pages([source]), title: title, into: emitter)
        default:
            try await DocumentRouter.readFile(url, into: emitter)
        }
    }

    private static func pages(_ data: [Data]) -> Pages {
        let decodable = pages(data.compactMap { CGImageSourceCreateWithData($0 as CFData, nil) })
        // Images that don't decode still count as pages, so the failure is reported rather than an empty scan.
        return decodable.count == 0 && !data.isEmpty ? Pages(count: data.count) { _ in nil } : decodable
    }

    /// Every image's pages: all frames of a multi-page TIFF, the first frame of anything else.
    private static func pages(_ sources: [CGImageSource]) -> Pages {
        var frames: [(source: CGImageSource, index: Int)] = []
        for source in sources {
            let count = CGImageSourceGetCount(source)
            guard count > 0 else { continue }
            let isTIFF = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)?.conforms(to: .tiff) ?? false
            for index in 0..<(isTIFF ? min(count, 500) : 1) { frames.append((source, index)) }
        }
        return Pages(count: frames.count) { i in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(frames[i].source, frames[i].index, options as CFDictionary)
        }
    }

    /// A PDF with a real text layer on most pages reads normally; a scanned one is rendered at about 2× and scanned.
    private static func readPDF(_ url: URL, title: String?, into emitter: BlockEmitter) throws {
        let worker = try PDFWorker(url: url)
        guard let survey = try worker.run(timeout: 30, { TextLayerSurvey($0) }) else {
            throw IngestError.unreadable("the PDF took too long to open.")
        }
        guard survey.pageCount > 0 else { throw IngestError.empty }
        if survey.hasTextLayer {
            try PDFReader.read(url: url, fallbackTitle: url.deletingPathExtension().lastPathComponent, into: emitter)
            return
        }
        let pages = Pages(count: survey.pageCount) { index in
            try worker.run(timeout: 30) { $0.page(at: index).flatMap(render) } ?? nil
        }
        try read(pages, title: title, into: emitter)
    }

    private struct TextLayerSurvey: Sendable {
        var pageCount: Int
        var hasTextLayer: Bool

        init(_ document: PDFDocument) {
            let pageCount = document.pageCount
            self.pageCount = pageCount
            let sample = pageCount <= 24 ? Array(0..<pageCount) : (0..<24).map { $0 * pageCount / 24 }
            let withText = sample.filter { index in
                let text = document.page(at: index)?.string ?? ""
                return text.unicodeScalars.lazy.filter { !TextNormalizer.isSpace($0) }.count >= 40
            }.count
            hasTextLayer = withText * 2 > sample.count
        }
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = min(max(2, 1600 / longest), CGFloat(maximumPixelSize) / longest)
        guard let ctx = ImageData.makeContext(width: Int(size.width * scale), height: Int(size.height * scale)) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// Camera, scanner and screenshot file names ("IMG_2041", "Scan 2024-03-01", "PXL_20240301_101112") say nothing.
    static func isGenericName(_ name: String) -> Bool {
        let generic: Set<String> = [
            "img", "image", "dsc", "dscn", "dscf", "pxl", "mvimg", "cimg", "photo", "picture", "pic", "scan", "scanned",
            "document", "doc", "page", "screenshot", "screen", "shot", "at", "untitled", "copy", "pm", "am",
        ]
        let words = name.lowercased().split { !$0.isLetter }.map(String.init)
        return words.allSatisfy(generic.contains)
    }

    // MARK: - Pages

    static func read(_ pages: Pages, title: String?, into emitter: BlockEmitter) throws {
        guard pages.count > 0 else { throw IngestError.empty }
        if let title { emitter.title(title) }
        let scanner = PageScanner()
        var scanned: [Int: ScannedPage] = [:]
        var decoded = 0
        var next = 0
        var builder = LineParagraphBuilder()
        var bodyHeight: CGFloat = 0
        func report(emitted: Int) {
            emitter.progress(Double(next + emitted) / Double(2 * pages.count))
        }

        for index in 0..<pages.count {
            try Task.checkCancellation()
            while next < pages.count, next <= index + lookahead {
                try Task.checkCancellation()
                var page = ScannedPage()
                if let image = try pages.image(next) {
                    decoded += 1
                    page = scanner.scan(image)
                    for line in page.lines { TextNormalizer.collectCompounds(in: line.text, into: &builder.compounds) }
                }
                scanned[next] = page
                if next == 0, title == nil { emitter.title(page.heading ?? "Scan") }
                next += 1
                report(emitted: index)
            }

            let page = scanned[index] ?? ScannedPage()
            let window = ((index - lookbehind)...(index + lookahead)).filter { $0 != index }.compactMap { scanned[$0] }
            let lines = bodyLines(of: page, neighbors: window, pageCount: pages.count)
            if lines.count >= 3 { bodyHeight = page.bodyLineHeight }
            builder.bodyLineHeight = bodyHeight
            emitter.emit(builder.addPage(lines: lines, images: page.images))
            report(emitted: index + 1)
            scanned.removeValue(forKey: index - lookbehind)
        }
        emitter.emit(builder.finish())
        if decoded == 0 { throw IngestError.unreadable("the image couldn't be decoded.") }
    }

    /// The page's lines without its running heads: those that look like one on their own, and,
    /// across several pages, edge lines repeated on a neighboring page.
    private static func bodyLines(of page: ScannedPage, neighbors: [ScannedPage], pageCount: Int) -> [TextLine] {
        let neighborKeys = neighbors.map { other in
            other.lines.indices.compactMap { i in other.edges[i].map { ($0, RunningContent.normalizedKey(other.lines[i].text)) } }
        }
        return page.lines.indices.compactMap { i in
            let line = page.lines[i]
            if page.running.contains(i) { return nil }
            guard pageCount > 1, let edge = page.edges[i], line.rect.height <= page.bodyLineHeight * 1.5 + 1 else { return line }
            let key = RunningContent.normalizedKey(line.text)
            let repeats = neighborKeys.contains { keys in keys.contains { $0.0 == edge && similar($0.1, key) } }
            return repeats ? nil : line
        }
    }

    /// Equal, or nearly so for longer keys, allowing for OCR's occasional misread letter.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        guard min(x.count, y.count) >= 8 else { return false }
        let allowed = max(x.count, y.count) / 8
        guard abs(x.count - y.count) <= allowed else { return false }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count] <= allowed
    }
}
