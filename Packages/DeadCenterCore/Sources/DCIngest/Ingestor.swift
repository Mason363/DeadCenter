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
    public static var supportedContentTypes: [UTType] { [] }

    /// Whether a file URL looks openable.
    public static func canOpen(_ url: URL) -> Bool { false }

    /// Streams the input's content in reading order. Never blocks the caller; heavy work runs off the main thread.
    public static func ingest(_ input: IngestInput) -> AsyncThrowingStream<IngestEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: IngestError.unsupported("these")) }
    }
}
