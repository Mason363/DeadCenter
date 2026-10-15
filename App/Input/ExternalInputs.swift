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

/// Picks up pages and selections the browser extensions drop into the shared App Group inbox.
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
            newest = payload
        }
        if let newest { read(newest) }
    }

    private func read(_ payload: InboxPayload) {
        let coordinator = ReadingCoordinator.shared
        let url = payload.url.flatMap(URL.init(string:))
        let browser = payload.browser?.capitalized
        switch payload.kind {
        case .selection:
            if let text = payload.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                coordinator.read(text: text, origin: .selection(app: browser))
            } else if let html = payload.html {
                coordinator.read(.html(html, baseURL: url, title: nil, origin: .selection(app: browser)))
            }
        case .page:
            if let html = payload.html, !html.isEmpty {
                coordinator.read(.html(html, baseURL: url, title: payload.title, origin: url.map(DocumentOrigin.web) ?? .text))
            } else if let text = payload.text, !text.isEmpty {
                var request = ReadRequest.text(text, origin: url.map(DocumentOrigin.web) ?? .text, title: payload.title)
                if let url { request.id = "web:" + ReadRequest.normalized(url) }
                coordinator.read(request)
            } else if let url {
                coordinator.read(.web(url))
            }
        case .hello:
            break
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
