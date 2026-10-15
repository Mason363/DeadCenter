import AppKit
import DCModel
import DCIngest

/// What a pasteboard (clipboard, drag, Services) holds that's worth reading.
enum PasteboardContent {
    case files([URL])
    case request(ReadRequest)
}

enum PasteboardReader {
    static func content(of pasteboard: NSPasteboard, origin: DocumentOrigin) -> PasteboardContent? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let string, !string.contains(where: \.isWhitespace), let url = URL(string: string),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil {
            return .request(.web(url))
        }
        let html = pasteboard.string(forType: .html)
        // Rich HTML only when it carries something plain text can't (images); otherwise text is more predictable.
        if let html, html.range(of: "<img", options: .caseInsensitive) != nil {
            return .request(.html(html, baseURL: nil, title: string.map(ReadRequest.title(from:)), origin: origin))
        }
        if let string, !string.isEmpty {
            // App data copied as JSON (Excalidraw, Figma, configs…): read the words inside, not the syntax.
            if let prose = JSONProse.text(in: string) {
                return prose.isEmpty ? nil : .request(.text(prose, origin: origin))
            }
            return .request(.text(string, origin: origin))
        }
        if let html {
            return .request(.html(html, baseURL: nil, title: nil, origin: origin))
        }
        if let rtf = pasteboard.data(forType: .rtf) {
            return .request(.rtf(rtf, origin: origin, title: nil))
        }
        if let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return .request(.image(image, origin: origin))
        }
        return nil
    }

    static func request(from pasteboard: NSPasteboard, origin: DocumentOrigin) -> ReadRequest? {
        switch content(of: pasteboard, origin: origin) {
        case .files(let urls): urls.first(where: Ingestor.canOpen).map(ReadRequest.file)
        case .request(let request): request
        case nil: nil
        }
    }
}

/// The smart hotkey: selection → the page you're on → the document you're in → the clipboard.
final class InputRouter {
    static let shared = InputRouter()
    private var busy = false

    func readSmart() {
        guard !busy else { return }
        busy = true
        let front = NSWorkspace.shared.frontmostApplication
        Task {
            await route(front: front)
            busy = false
        }
    }

    private func route(front: NSRunningApplication?) async {
        let coordinator = ReadingCoordinator.shared
        guard let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return coordinator.readClipboard()
        }
        let browsers = BrowserIntegration.shared
        let isBrowser = browsers.isBrowser(front)

        if !SelectionGrabber.isTrusted {
            // Without Accessibility we can't see selections; the clipboard is the honest fallback.
            return coordinator.readClipboard()
        }

        if case .text(let text) = await SelectionGrabber.selection(in: front, isBrowser: isBrowser) {
            return coordinator.read(text: text, origin: .selection(app: front.localizedName))
        }

        if isBrowser {
            if browsers.requestPageFromExtension(in: front) {
                let waiting = coordinator.showWaiting()
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                    // The page arrived through the inbox and replaced the waiting session.
                    if coordinator.session !== waiting { return }
                }
            }
            if let url = await browsers.frontTabURL(of: front) {
                return coordinator.read(.web(url))
            }
        }

        if let document = await SelectionGrabber.documentURL(in: front) {
            return coordinator.open([document])
        }

        coordinator.readClipboard()
    }
}

/// Pulls readable text out of JSON: string values that look like words, in document order.
enum JSONProse {
    /// nil when the text isn't JSON; empty when it's JSON without any prose.
    static func text(in string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var lines: [String] = []
        collect(object, into: &lines)
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }.joined(separator: "\n\n")
    }

    private static func collect(_ value: Any, into lines: inout [String]) {
        switch value {
        case let dict as [String: Any]:
            // Prefer the keys apps use for visible text, then everything else in a stable order.
            let preferred = ["text", "originalText", "title", "name", "content", "body", "description", "label"]
            for key in preferred { if let v = dict[key] { collect(v, into: &lines) } }
            for key in dict.keys.sorted() where !preferred.contains(key) {
                if let v = dict[key], !(v is String) { collect(v, into: &lines) }
            }
        case let array as [Any]:
            for v in array { collect(v, into: &lines) }
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeProse(t) { lines.append(t) }
        default:
            break
        }
    }

    /// Words, not identifiers, colors, URLs or numbers.
    private static func looksLikeProse(_ s: String) -> Bool {
        guard s.count >= 2, s.contains(where: \.isLetter) else { return false }
        if s.hasPrefix("#") || s.hasPrefix("http") || s.hasPrefix("data:") { return false }
        let letters = s.filter(\.isLetter).count
        let hasSpace = s.contains(" ")
        // Single tokens must read like a word, not "KOZ1dA6qc8C" or "strokeColor".
        if !hasSpace {
            let lowerAfterFirst = s.dropFirst().allSatisfy { !$0.isUppercase }
            return letters == s.count && lowerAfterFirst && s.count <= 24
        }
        return Double(letters) / Double(s.count) > 0.5
    }
}
