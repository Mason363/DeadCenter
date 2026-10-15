import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import DCModel
@testable import DCIngest

/// Everything a stream produced.
struct IngestResult {
    var titles: [String] = []
    var blocks: [Block] = []
    var progress: [Double] = []
    var batches = 0

    var title: String? { titles.last }

    var paragraphs: [String] { blocks.compactMap { if case .paragraph(let t) = $0 { t } else { nil } } }
    var headings: [String] { blocks.compactMap { if case .heading(let t, _) = $0 { t } else { nil } } }
    var chapters: [String] { blocks.compactMap { if case .chapter(let t) = $0 { t } else { nil } } }
    var images: [ImageAsset] { blocks.compactMap { if case .image(let a) = $0 { a } else { nil } } }

    /// All readable text joined with spaces.
    var text: String { blocks.compactMap { b -> String? in
        switch b {
        case .paragraph(let t), .heading(let t, _): t
        default: nil
        }
    }.joined(separator: " ") }

    /// A compact outline of the blocks, for readable assertion failures.
    var outline: String {
        blocks.map { block in
            switch block {
            case .chapter(let t): "[C] \(t)"
            case .heading(let t, let l): "[H\(l)] \(t)"
            case .paragraph(let t): "[P] \(t)"
            case .image(let a): a.caption.map { "[I] \($0)" } ?? "[I]"
            }
        }.joined(separator: "\n")
    }
}

func collect(_ stream: AsyncThrowingStream<IngestEvent, Error>) async throws -> IngestResult {
    var result = IngestResult()
    for try await event in stream {
        switch event {
        case .title(let t): result.titles.append(t)
        case .blocks(let b): result.blocks += b; result.batches += 1
        case .progress(let p): result.progress.append(p)
        }
    }
    return result
}

func ingest(_ input: IngestInput) async throws -> IngestResult {
    try await collect(Ingestor.ingest(input))
}

/// Runs a reader directly with a fresh emitter (for internal entry points).
func run(_ body: @escaping @Sendable (BlockEmitter) async throws -> Void) async throws -> IngestResult {
    let stream = AsyncThrowingStream<IngestEvent, Error> { continuation in
        Task {
            let emitter = BlockEmitter(continuation)
            do {
                try await body(emitter)
                try emitter.finish()
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
    return try await collect(stream)
}

/// A fresh temporary directory, removed when the value is deallocated.
final class TemporaryDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DCIngestTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    @discardableResult
    func write(_ data: Data, to name: String) throws -> URL {
        let file = file(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    @discardableResult
    func write(_ text: String, to name: String, encoding: String.Encoding = .utf8) throws -> URL {
        try write(text.data(using: encoding)!, to: name)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

enum TestImages {
    /// A solid-color image with a contrasting square, so it isn't uniform.
    static func cgImage(width: Int, height: Int, red: CGFloat = 0.85, green: CGFloat = 0.1, blue: CGFloat = 0.1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    static func png(width: Int, height: Int, red: CGFloat = 0.85, green: CGFloat = 0.1, blue: CGFloat = 0.1) -> Data {
        encode(cgImage(width: width, height: height, red: red, green: green, blue: blue), type: .png)
    }

    static func encode(_ image: CGImage, type: UTType) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Black text on white, one line per entry, for OCR.
    static func textImage(_ lines: [String], fontSize: CGFloat = 36, width: Int = 1600) -> CGImage {
        let lineHeight = fontSize * 1.5
        let height = Int(CGFloat(lines.count) * lineHeight + fontSize * 3)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        for (i, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: fontSize, y: CGFloat(height) - fontSize * 1.5 - CGFloat(i) * lineHeight - fontSize)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()!
    }
}

extension ImageAsset {
    var data: Data? { if case .data(let d) = source { d } else { nil } }
    var url: URL? { if case .url(let u) = source { u } else { nil } }
}
