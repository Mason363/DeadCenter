import Foundation

/// One unit of readable content, produced by ingestion and consumed by the engine.
///
/// Ingestors emit blocks in reading order. The engine turns paragraphs and headings into
/// words, images into timed image beats, and chapters into navigation markers.
public enum Block: Sendable, Hashable, Codable {
    /// A navigation boundary (EPUB TOC entry, PDF outline item, web article title).
    /// Not read word by word; shown briefly as a title card and used for ⌘[ / ⌘].
    case chapter(String)
    /// A heading inside the flow. Read as words, followed by a longer pause.
    case heading(String, level: Int)
    /// Plain running text. Line breaks inside are treated as spaces.
    case paragraph(String)
    /// An inline image shown as a timed beat at this point in the flow.
    case image(ImageAsset)
}

public struct ImageAsset: Sendable, Hashable, Codable {
    public enum Source: Sendable, Hashable, Codable {
        /// Encoded image bytes (PNG, JPEG, HEIC, GIF, TIFF…).
        case data(Data)
        /// A file or http(s) URL, loaded lazily when the beat is about to show.
        case url(URL)
    }

    public var source: Source
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Alt text or figure caption, if any.
    public var caption: String?

    public init(source: Source, pixelWidth: Int? = nil, pixelHeight: Int? = nil, caption: String? = nil) {
        self.source = source
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.caption = caption
    }
}

/// Events streamed by an ingestor so reading can start before a large file finishes parsing.
public enum IngestEvent: Sendable {
    /// Best title for the document (file metadata, `<title>`, EPUB `dc:title`…). May arrive late.
    case title(String)
    /// The next blocks in reading order.
    case blocks([Block])
    /// Fraction (0…1) of the source processed so far.
    case progress(Double)
}

/// Where a reading came from. Used for the library, titles, and resume.
public enum DocumentOrigin: Sendable, Hashable, Codable {
    case clipboard
    case selection(app: String?)
    case file(URL)
    case web(URL)
    /// Text handed over by Services, the URL scheme, or Shortcuts.
    case text
}
