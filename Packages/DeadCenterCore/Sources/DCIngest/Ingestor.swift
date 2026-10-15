import Foundation
import UniformTypeIdentifiers
import DCModel

/// What can be handed to ingestion.
public enum IngestInput: Sendable {
    /// A local file of any supported type.
    case file(URL)
    /// Plain text. Markdown syntax is detected and cleaned up.
    case text(String)
    /// An HTML document or fragment (browser extension, pasteboard HTML).
    case html(String, baseURL: URL?)
    /// RTF data from the pasteboard.
    case rtf(Data)
    /// A web page to fetch and reduce to its article.
    case web(URL)
    /// Encoded image bytes to OCR.
    case image(Data)
    /// Photos or scans of printed pages (textbooks, papers): straightened, OCR'd into
    /// paragraphs, with figures, captions and display equations kept as images.
    case scan(ScanSource)
}

/// Pages for `IngestInput.scan`.
public enum ScanSource: Sendable {
    /// Encoded photos or scans (JPEG, HEIC, PNG, TIFF), one page each, in order.
    case images([Data])
    /// An image file (every page of a multi-page TIFF) or a PDF. A PDF with a real text layer
    /// on most pages is read as an ordinary PDF.
    case file(URL)
}

public enum IngestError: LocalizedError, Sendable {
    case unsupported(String)
    case empty
    case unreadable(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let what): "Dead Center can't read \(what) files yet."
        case .empty: "There's no readable text here."
        case .unreadable(let why): "Couldn't read this: \(why)"
        case .network(let why): "Couldn't load the page: \(why)"
        }
    }
}

public enum Ingestor {
    /// Content types the app declares it can open (Open panel, Finder "Open With", drops).
    public static var supportedContentTypes: [UTType] { DocumentFormat.contentTypes }

    /// Whether a file URL looks openable.
    public static func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return DocumentFormat.declared(by: url) != nil
    }

    /// Streams the input's content in reading order. Never blocks the caller; heavy work runs off the main thread.
    public static func ingest(_ input: IngestInput) -> AsyncThrowingStream<IngestEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let emitter = BlockEmitter(continuation)
                do {
                    try await DocumentRouter.route(input, into: emitter)
                    try Task.checkCancellation()
                    try emitter.finish()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.presentable(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Maps lower-level failures to friendly `IngestError`s.
    static func presentable(_ error: any Error) -> any Error {
        switch error {
        case is IngestError, is CancellationError:
            return error
        case let error as URLError:
            return IngestError.network(error.localizedDescription)
        case let error as CocoaError where error.code == .fileReadNoPermission:
            return IngestError.unreadable("Dead Center doesn't have permission to open it.")
        case let error as CocoaError where error.code == .fileReadNoSuchFile:
            return IngestError.unreadable("the file couldn't be found.")
        default:
            return IngestError.unreadable(error.localizedDescription)
        }
    }
}
