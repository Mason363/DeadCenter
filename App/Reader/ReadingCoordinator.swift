import AppKit
import UniformTypeIdentifiers
import QuartzCore
import DCModel
import DCIngest
import DCEngine

/// Owns the reader window and the current reading; every source of text ends up here.
final class ReadingCoordinator {
    static let shared = ReadingCoordinator()

    let window = ReaderWindowController()
    private(set) var session: ReaderSession?
    private var request: ReadRequest?
    private let library = LibraryStore.shared
    private var lastSaved: CFTimeInterval = 0

    init() {
        window.onClose = { [weak self] in self?.windowClosed() }
    }

    var hasSession: Bool { session != nil }

    // MARK: - Reading

    func read(_ request: ReadRequest) {
        saveProgress()
        session?.pause()
        session?.cancelLoading()

        let entry = library.entry(id: request.id)
        let resume = entry.flatMap { !$0.finished && $0.position > 0 ? $0.position : nil }
        // A file's name is only a stand-in until its own title (EPUB, PDF metadata) arrives.
        let isFile: Bool = { if case .file = request.origin { return true } else { return false } }()
        let session = ReaderSession(id: request.id, title: isFile ? nil : (request.title ?? entry?.title),
                                    origin: request.origin)
        if isFile { session.setFallbackTitle(entry?.title ?? request.title ?? "") }
        session.onProgress = { [weak self] s in self?.progressChanged(s) }
        if case .text = request.stored { session.isEditable = true }
        self.session = session
        self.request = request
        library.record(request, title: session.title)

        window.show(session)
        session.load(request.input, resumeAt: resume)
        if Preferences.shared.autoStart { session.play() }
        if resume != nil { window.readerView.flash("Resuming where you left off") }
    }

    func read(text: String, origin: DocumentOrigin = .text, title: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return showMessage("Nothing to read.") }
        read(.text(trimmed, origin: origin, title: title))
    }

    func open(_ urls: [URL]) {
        // Recordings and videos go to transcription.
        if !urls.contains(where: Ingestor.canOpen), let media = urls.first(where: TranscriptionController.canTranscribe) {
            if window.isVisible { window.close() }
            return TranscriptionController.shared.transcribe(file: media)
        }
        guard let url = urls.first(where: Ingestor.canOpen) ?? urls.first else { return }
        guard Ingestor.canOpen(url) else {
            return showMessage("Dead Center can't read .\(url.pathExtension) files.")
        }
        read(.file(url))
    }

    func readClipboard() {
        guard let request = PasteboardReader.request(from: .general, origin: .clipboard) else {
            return showMessage("Your clipboard is empty. Copy some text, a link, or a file.")
        }
        read(request)
    }

    func resume(_ entry: LibraryEntry) {
        if let session, session.id == entry.id {
            window.show(session)
            return
        }
        guard let request = library.request(for: entry) else {
            library.remove(id: entry.id)
            return showMessage("“\(entry.title)” is no longer available.")
        }
        read(request)
    }

    /// Opens the reader on a calm message instead of content.
    func showMessage(_ message: String) {
        saveProgress()
        session?.pause()
        session?.cancelLoading()
        let session = ReaderSession(id: "message", title: nil, origin: .text)
        self.session = session
        request = nil
        window.show(session)
        session.fail(message)
    }

    /// Shows the reader in its loading state while something else fetches the content.
    func showWaiting(title: String? = nil) -> ReaderSession {
        saveProgress()
        session?.pause()
        session?.cancelLoading()
        let session = ReaderSession(id: "waiting", title: title, origin: .text)
        self.session = session
        request = nil
        window.show(session)
        return session
    }

    /// The Library's blank page to paste or type into; ⌘↩ reads it.
    func compose() {
        if window.isVisible { window.close() }
        LibraryWindowController.shared.compose()
    }

    /// Applies text edited on the page and remembers it for resuming.
    func applyEdit(text: String, atWord word: Int) {
        guard let session else { return }
        // A fresh composition starts at the top; an edit keeps your place.
        session.replaceText(text, atWord: session.stream.isEmpty ? 0 : word)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var updated = request ?? ReadRequest(input: .text(text), title: session.title, origin: session.origin,
                                             id: session.id, stored: nil)
        updated.input = .text(text)
        updated.stored = .text(text)
        request = updated
        library.record(updated, title: session.title)
        saveProgress()
    }

    func showReader() {
        guard let session else { return }
        window.show(session)
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Ingestor.supportedContentTypes + TranscriptionController.supportedFileTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose something to read"
        panel.prompt = "Read"
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open([url])
        }
    }

    // MARK: - Progress

    private func progressChanged(_ session: ReaderSession) {
        guard session === self.session, request != nil else { return }
        let now = CACurrentMediaTime()
        let important = session.state != .playing
        guard important || now - lastSaved > 3 else { return }
        lastSaved = now
        saveProgress()
    }

    func saveProgress() {
        guard let session, request != nil else { return }
        // Something that turned out to have nothing to read doesn't belong in the library.
        if case .failed = session.state, session.stream.isEmpty {
            library.remove(id: session.id)
            request = nil
            return
        }
        guard !session.stream.isEmpty else { return }
        library.updateProgress(id: session.id, title: session.title, position: session.index,
                               itemCount: session.stream.count, finished: session.state == .finished,
                               wordCount: session.isIngesting ? nil : session.stream.wordCount,
                               snippet: snippetFromStream(session))
    }

    /// The opening words of a document, for the library (files have no stored text).
    private func snippetFromStream(_ session: ReaderSession) -> String? {
        var text = ""
        var count = 0
        var paragraph = -1
        for item in session.stream.items where item.kind == .word {
            if !text.isEmpty, item.spaceBefore || item.paragraph != paragraph { text += " " }
            paragraph = item.paragraph
            text += item.sourceText
            count += 1
            if count >= 60 { break }
        }
        // Don't repeat the title as the preview's opening words.
        let title = session.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, text.hasPrefix(title), text.count > title.count + 10 {
            text = String(text.dropFirst(title.count)).trimmingCharacters(in: .whitespaces)
        }
        return LibraryStore.snippet(from: text)
    }

    /// Opens an entry from its first word.
    func restart(_ entry: LibraryEntry) {
        library.restart(id: entry.id)
        if let session, session.id == entry.id {
            session.seekToStart()
            window.show(session)
            if Preferences.shared.autoStart { session.play() }
            return
        }
        resume(entry)
    }

    private func windowClosed() {
        session?.pause()
        saveProgress()
        library.save()
        if let session, session.id == "message" || session.id == "waiting" {
            self.session = nil
        }
    }
}
