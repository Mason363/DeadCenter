import Foundation
import Observation
import CryptoKit
import UniformTypeIdentifiers
import DCModel
import DCIngest

/// Source material for readings that have no file to reopen (clipboard, selections, extension pages).
enum StoredInput: Codable {
    case text(String)
    case html(String, baseURL: URL?)
    case rtf(Data)

    var ingestInput: IngestInput {
        switch self {
        case .text(let s): .text(s)
        case .html(let html, let base): .html(html, baseURL: base)
        case .rtf(let data): .rtf(data)
        }
    }
}

/// Everything needed to start (and later resume) a reading.
struct ReadRequest {
    var input: IngestInput
    var title: String?
    var origin: DocumentOrigin
    var id: String
    var stored: StoredInput?

    static func file(_ url: URL) -> ReadRequest {
        let url = url.standardizedFileURL
        // Saved scans always read as pages; other photos and image-only PDFs do once page scans are on.
        let scan = ScanStore.contains(url) || (Preferences.shared.pageScanning && Self.isPageLike(url))
        return ReadRequest(input: scan ? .scan(.file(url)) : .file(url), title: url.deletingPathExtension().lastPathComponent,
                           origin: .file(url), id: "file:" + url.path, stored: nil)
    }

    /// Images and PDFs: what a photo or scan of a page arrives as.
    private static func isPageLike(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    static func web(_ url: URL) -> ReadRequest {
        ReadRequest(input: .web(url), title: nil, origin: .web(url), id: "web:" + Self.normalized(url), stored: nil)
    }

    /// Without a title, the reading takes the one ingestion derives from the cleaned text.
    static func text(_ text: String, origin: DocumentOrigin, title: String? = nil) -> ReadRequest {
        ReadRequest(input: .text(text), title: title, origin: origin,
                    id: "text:" + Self.digest(text), stored: .text(text))
    }

    static func html(_ html: String, baseURL: URL?, title: String?, origin: DocumentOrigin) -> ReadRequest {
        let id = baseURL.map { "web:" + Self.normalized($0) } ?? "html:" + Self.digest(html)
        return ReadRequest(input: .html(html, baseURL: baseURL), title: title, origin: origin, id: id,
                           stored: .html(html, baseURL: baseURL))
    }

    static func rtf(_ data: Data, origin: DocumentOrigin, title: String?) -> ReadRequest {
        ReadRequest(input: .rtf(data), title: title, origin: origin, id: "rtf:" + Self.digest(data), stored: .rtf(data))
    }

    static func image(_ data: Data, origin: DocumentOrigin) -> ReadRequest {
        let input: IngestInput = Preferences.shared.pageScanning ? .scan(.images([data])) : .image(data)
        return ReadRequest(input: input, title: "Image", origin: origin, id: "image:" + Self.digest(data), stored: nil)
    }

    static func normalized(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string ?? url.absoluteString
    }

    static func digest(_ text: String) -> String { digest(Data(text.utf8)) }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// A short title from the first words of a text.
    static func title(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
        guard words.count > 48 else { return words }
        let cut = words.prefix(46)
        let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return trimmed + "…"
    }
}

struct LibraryEntry: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var origin: DocumentOrigin
    var position: Int
    var itemCount: Int
    var finished: Bool
    var lastOpened: Date
    /// The first words, for pasted text and web pages.
    var snippet: String?
    var wordCount: Int?

    var progress: Double {
        if finished { return 1 }
        return itemCount > 1 ? min(Double(position) / Double(itemCount - 1), 1) : 0
    }
}

/// Recent readings and where you left off. Stored as small JSON files in Application Support.
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var entries: [LibraryEntry] = []
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    private static let maxEntries = 60
    private static let maxAge: TimeInterval = 90 * 24 * 3600

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Dead Center", isDirectory: true)
        try? FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        load()
        NotificationCenter.default.addObserver(forName: Notification.Name("DeadCenterClearHistory"),
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LibraryStore.shared.clear() }
        }
    }

    private var indexURL: URL { directory.appendingPathComponent("Library.json") }
    private var payloadDirectory: URL { directory.appendingPathComponent("Readings", isDirectory: true) }

    private func payloadURL(_ id: String) -> URL {
        payloadDirectory.appendingPathComponent(ReadRequest.digest(id) + ".json")
    }

    func entry(id: String) -> LibraryEntry? {
        entries.first { $0.id == id }
    }

    func recents(limit: Int = 6) -> [LibraryEntry] {
        Array(entries.sorted { $0.lastOpened > $1.lastOpened }.prefix(limit))
    }

    var all: [LibraryEntry] {
        entries.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Notes that a reading was opened. Does nothing when history is off.
    func record(_ request: ReadRequest, title: String) {
        guard Preferences.shared.rememberHistory else { return }
        if case .image = request.input { return }
        if let stored = request.stored, let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: payloadURL(request.id), options: .atomic)
        }
        // Previews come from the cleaned reading stream (see updateProgress), never the raw source.
        let snippet: String? = nil
        if let i = entries.firstIndex(where: { $0.id == request.id }) {
            entries[i].lastOpened = Date()
            if !title.isEmpty { entries[i].title = title }
            if let snippet { entries[i].snippet = snippet }
        } else {
            entries.append(LibraryEntry(id: request.id, title: title, origin: request.origin, position: 0,
                                        itemCount: 0, finished: false, lastOpened: Date(), snippet: snippet))
        }
        prune()
        scheduleSave()
    }

    func updateProgress(id: String, title: String, position: Int, itemCount: Int, finished: Bool,
                        wordCount: Int? = nil, snippet: String? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].position = position
        entries[i].itemCount = itemCount
        entries[i].finished = finished
        if !title.isEmpty { entries[i].title = title }
        if let wordCount { entries[i].wordCount = wordCount }
        if let snippet { entries[i].snippet = snippet }
        scheduleSave()
    }

    /// Marks an entry to start over from the top next time it's opened.
    func restart(id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].position = 0
        entries[i].finished = false
        scheduleSave()
    }

    static func snippet(from text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(40).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > 180 ? String(words.prefix(178)) + "…" : words
    }

    /// Rebuilds the request that reopens an entry, or nil if its source is gone.
    func request(for entry: LibraryEntry) -> ReadRequest? {
        switch entry.origin {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var request = ReadRequest.file(url)
            request.title = entry.title
            return request
        case .web(let url):
            if let stored = storedInput(for: entry.id) {
                return ReadRequest(input: stored.ingestInput, title: entry.title, origin: entry.origin,
                                   id: entry.id, stored: stored)
            }
            var request = ReadRequest.web(url)
            request.title = entry.title
            return request
        case .clipboard, .selection, .text:
            guard let stored = storedInput(for: entry.id) else { return nil }
            return ReadRequest(input: stored.ingestInput, title: entry.title, origin: entry.origin,
                               id: entry.id, stored: stored)
        }
    }

    private func storedInput(for id: String) -> StoredInput? {
        guard let data = try? Data(contentsOf: payloadURL(id)) else { return nil }
        return try? JSONDecoder().decode(StoredInput.self, from: data)
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: payloadURL(id))
        scheduleSave()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: payloadDirectory)
        try? FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        save()
    }

    func prune() {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        let sorted = entries.sorted { $0.lastOpened > $1.lastOpened }
        let keep = sorted.prefix(Self.maxEntries).filter { $0.lastOpened > cutoff }
        let dropped = Set(entries.map(\.id)).subtracting(keep.map(\.id))
        guard !dropped.isEmpty else { return }
        for id in dropped { try? FileManager.default.removeItem(at: payloadURL(id)) }
        entries = Array(keep)
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LibraryEntry].self, from: data) else { return }
        // Entries saved before Markdown cleanup may carry raw syntax in their titles and previews.
        entries = decoded.map { entry in
            var e = entry
            e.title = Self.scrubbed(e.title)
            e.snippet = e.snippet.map(Self.scrubbed)
            return e
        }
    }

    /// Removes leftover Markdown markers ("**", "##", "`", list dashes) from a line of text.
    static func scrubbed(_ text: String) -> String {
        guard text.contains(where: { "*_`#[|~".contains($0) }) else { return text }
        var t = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*\*|__|~~|`|(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(^|\s)#{1,6}\s"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(^|:)\s*[-*+]\s+"#, with: "$1 ", options: .regularExpression)
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func save() {
        saveWork?.cancel()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
