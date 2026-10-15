import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image files and image data: OCR'd into paragraphs (the image itself isn't shown).
enum ImageReader {
    static func read(url: URL, into emitter: BlockEmitter) throws {
        emitter.title(url.deletingPathExtension().lastPathComponent)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw IngestError.unreadable("the image couldn't be decoded.")
        }
        try recognize(source, into: emitter)
    }

    static func read(data: Data, into emitter: BlockEmitter) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw IngestError.unreadable("the image couldn't be decoded.")
        }
        try recognize(source, into: emitter)
    }

    private static func recognize(_ source: CGImageSource, into emitter: BlockEmitter) throws {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw IngestError.unreadable("the image couldn't be decoded.") }
        // Multi-page TIFFs (faxes, scans) are documents; other formats' extra frames are animation.
        let isTIFF = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)?.conforms(to: .tiff) ?? false
        let frames = isTIFF ? min(count, 200) : 1

        var builder = LineParagraphBuilder()
        for index in 0..<frames {
            try Task.checkCancellation()
            guard let image = frame(index, of: source) else { continue }
            let size = CGSize(width: image.width, height: image.height)
            let lines = try TextRecognizer.lines(in: image, size: size)
            let heights = lines.map(\.rect.height).sorted()
            builder.bodyLineHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
            emitter.emit(builder.addPage(lines: lines))
            emitter.progress(Double(index + 1) / Double(frames))
        }
        emitter.emit(builder.finish())
    }

    private static func frame(_ index: Int, of source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}
