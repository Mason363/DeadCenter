import AppKit
import DCModel
import DCIngest

/// Right-click ▸ Services ▸ Read in Dead Center, in every app.
final class ServicesProvider: NSObject {
    @objc func readText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pasteboard)
    }

    @objc func readFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pasteboard)
    }

    private func handle(_ pasteboard: NSPasteboard) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        switch PasteboardReader.content(of: pasteboard, origin: .selection(app: app)) {
        case .files(let urls): ReadingCoordinator.shared.open(urls)
        case .request(let request): ReadingCoordinator.shared.read(request)
        case nil: ReadingCoordinator.shared.showMessage("Nothing to read.")
        }
    }
}

/// Picks up what the browser extensions and AI assistants drop into the shared App Group inbox.
final class InboxWatcher {
    static let shared = InboxWatcher()
    private var source: DispatchSourceFileSystemObject?

    func start() {
        try? FileManager.default.createDirectory(at: Inbox.directory, withIntermediateDirectories: true)
        let fd = open(Inbox.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        drain()
    }

    func drain() {
        var newest: InboxPayload?
        for url in Inbox.pending() {
            guard let payload = try? Inbox.take(url) else { continue }
            // Ignore anything stale (e.g. sent while the app wasn't running, long ago).
            guard payload.kind != .hello, Date().timeIntervalSince(payload.sentAt) < 300 else { continue }
            if payload.later == true {
                // Saved for later: every one goes to the Library, none interrupts.
                if let request = Self.request(for: payload) { ReadingCoordinator.shared.saveForLater(request) }
            } else {
                newest = payload
            }
        }
        if let newest { read(newest) }
    }

    private func read(_ payload: InboxPayload) {
        if payload.kind == .file, let path = payload.path {
            // Opening routes recordings to transcription and explains unsupported files.
            return ReadingCoordinator.shared.open([URL(fileURLWithPath: path)])
        }
        if let request = Self.request(for: payload) { ReadingCoordinator.shared.read(request) }
    }

    /// What a payload asks to read.
    static func request(for payload: InboxPayload) -> ReadRequest? {
        let url = payload.url.flatMap(URL.init(string:))
        let source = payload.browser?.capitalized
        func trimmed(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        switch payload.kind {
        case .selection:
            if let text = trimmed(payload.text) { return .text(text, origin: .selection(app: source)) }
            return payload.html.map { .html($0, baseURL: url, title: nil, origin: .selection(app: source)) }
        case .page:
            if let html = payload.html, !html.isEmpty {
                return .html(html, baseURL: url, title: payload.title, origin: url.map(DocumentOrigin.web) ?? .text)
            }
            if let text = trimmed(payload.text) {
                var request = ReadRequest.text(text, origin: url.map(DocumentOrigin.web) ?? .text, title: payload.title)
                if let url { request.id = "web:" + ReadRequest.normalized(url) }
                return request
            }
            return url.map(ReadRequest.web)
        case .text:
            return trimmed(payload.text).map { .text($0, origin: .text, title: trimmed(payload.title)) }
        case .file:
            guard let path = payload.path else { return nil }
            let file = URL(fileURLWithPath: path)
            return Ingestor.canOpen(file) ? .file(file) : nil
        case .hello:
            return nil
        }
    }
}

/// `deadcenter://` links and files opened from Finder.
enum URLRouter {
    static func handle(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { ReadingCoordinator.shared.open(files) }
        for url in urls where url.scheme == Inbox.urlScheme {
            route(url)
        }
    }

    private static func route(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let coordinator = ReadingCoordinator.shared
        switch url.host {
        case "inbox":
            InboxWatcher.shared.drain()
        case "read":
            if let text = value("text") { coordinator.read(text: text, title: value("title")) }
        case "open":
            if let link = value("url").flatMap(URL.init(string:)) {
                coordinator.read(.web(link))
            } else if let path = value("path") {
                coordinator.open([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
            }
        case "clipboard":
            coordinator.readClipboard()
        #if DEBUG
        case "debug":
            DebugCommands.run(items)
        #endif
        default:
            break
        }
    }
}
