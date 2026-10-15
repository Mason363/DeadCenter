import Foundation
import ImageIO
import DCModel

/// Sends each input to the reader for its format.
enum DocumentRouter {
    /// Text-based files larger than this are refused rather than loaded into memory.
    private static let maximumTextFileSize = 256 * 1024 * 1024

    static func route(_ input: IngestInput, into emitter: BlockEmitter) async throws {
        switch input {
        case .file(let url):
            try await readFile(url, into: emitter)
        case .text(let text):
            try PlainTextReader.readString(text, into: emitter)
        case .html(let html, let baseURL):
            try HTMLDocumentReader.read(html: html, baseURL: baseURL, resolver: URLImageResolver(baseURL: baseURL),
                                        mode: .direct, fallbackTitle: nil, into: emitter)
        case .rtf(let data):
            try RichTextReader.read(data: data, into: emitter)
        case .web(let url):
            if url.isFileURL {
                try await readFile(url, into: emitter)
            } else {
                try await WebReader.read(url, into: emitter)
            }
        case .image(let data):
            try ImageReader.read(data: data, into: emitter)
        case .scan(let source):
            try await PageScanReader.read(source, into: emitter)
        }
    }

    /// Reads a local file. `title` replaces the file name as the fallback title (for downloads).
    static func readFile(_ url: URL, title: String? = nil, into emitter: BlockEmitter) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw IngestError.unreadable("the file couldn't be found.")
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw IngestError.unreadable("Dead Center doesn't have permission to open it.")
        }
        guard let format = DocumentFormat.declared(by: url) ?? sniffedFormat(of: url) else {
            let ext = url.pathExtension
            throw IngestError.unsupported(ext.isEmpty ? "these" : ext.uppercased())
        }
        let fallbackTitle = title ?? url.deletingPathExtension().lastPathComponent

        switch format {
        case .plainText:
            emitter.title(fallbackTitle)
            try PlainTextReader.read(TextDecoding.decode(try textData(url)), into: emitter)
        case .markdown:
            try MarkdownReader.read(TextDecoding.decode(try textData(url)), baseURL: url, fallbackTitle: fallbackTitle, into: emitter)
        case .latex:
            try LaTeXDocumentReader.read(TextDecoding.decode(try textData(url)), fallbackTitle: fallbackTitle, into: emitter)
        case .rtf:
            try RichTextReader.read(url: url, type: .rtf, into: emitter)
        case .rtfd:
            try RichTextReader.read(url: url, type: .rtfd, into: emitter)
        case .doc:
            try RichTextReader.read(url: url, type: .docFormat, into: emitter)
        case .odt:
            try RichTextReader.read(url: url, type: .openDocument, into: emitter)
        case .docx:
            try DOCXReader.read(url: url, into: emitter)
        case .html:
            let html = TextDecoding.decodeHTML(try textData(url))
            try HTMLDocumentReader.read(html: html, baseURL: url, resolver: URLImageResolver(baseURL: url),
                                        mode: .automatic, fallbackTitle: fallbackTitle, into: emitter)
        case .webArchive:
            try await WebArchiveReader.read(url: url, into: emitter)
        case .pdf:
            try PDFReader.read(url: url, fallbackTitle: fallbackTitle, into: emitter)
        case .epub:
            try EPUBReader.read(url: url, into: emitter)
        case .image:
            try ImageReader.read(url: url, into: emitter)
        }
    }

    /// Reads downloaded bytes (a fetched PDF, a web archive's main resource) through a temporary file.
    static func readDownloaded(_ data: Data, mimeType: String?, suggestedName: String?, fallbackTitle: String,
                               into emitter: BlockEmitter) async throws {
        let suggested = suggestedName.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        let format = mimeType.flatMap(DocumentFormat.format(mimeType:))
            ?? suggested.flatMap { DocumentFormat.declared(by: URL(fileURLWithPath: $0)) }
            ?? DocumentFormat.sniff(data)
        guard let format else { throw IngestError.unsupported(mimeType ?? "these") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeadCenterIngest", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("download").appendingPathExtension(format.filenameExtension)
        try data.write(to: file)

        let title = suggested.map { ($0 as NSString).deletingPathExtension.removingPercentEncoding ?? $0 }.flatMap { $0.isBlank ? nil : $0 }
        try await readFile(file, title: title ?? fallbackTitle, into: emitter)
    }

    private static func textData(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maximumTextFileSize else { throw IngestError.unreadable("the file is too large.") }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func sniffedFormat(of url: URL) -> DocumentFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), !head.isEmpty else { return nil }
        let format = DocumentFormat.sniff(head)
        // An image signature check needs the whole file; confirm with ImageIO on the URL.
        if format == nil || format == .image {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) != nil { return .image }
        }
        return format
    }
}
