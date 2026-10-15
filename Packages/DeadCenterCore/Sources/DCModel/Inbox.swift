import Foundation

/// A reading handed to the app from outside its process: the browser native-messaging bridge
/// or the Safari web extension. Delivered as a JSON file in the shared App Group inbox.
public struct InboxPayload: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A whole article. `html` holds Readability's cleaned content; `text` is a fallback.
        case page
        /// The user's selection. `text` holds it; `html` may hold the selection's markup.
        case selection
        /// The extension announcing it is installed and connected. Nothing to read.
        case hello
    }

    public var kind: Kind
    /// "chrome", "zen", "firefox", "safari", "arc", "brave", "edge"…
    public var browser: String?
    public var title: String?
    public var url: String?
    public var html: String?
    public var text: String?
    public var sentAt: Date

    public init(kind: Kind, browser: String? = nil, title: String? = nil, url: String? = nil,
                html: String? = nil, text: String? = nil, sentAt: Date = Date()) {
        self.kind = kind
        self.browser = browser
        self.title = title
        self.url = url
        self.html = html
        self.text = text
        self.sentAt = sentAt
    }
}

/// The shared drop box between the app, the native-messaging bridge, and the Safari extension.
///
/// Writers call `deliver(_:)` and then open `wakeURL(for:)` so the app launches (or wakes) and
/// picks the file up. The app also watches `directory` while running.
public enum Inbox {
    public static let appGroup = "8GFSXN32MA.com.mason363.DeadCenter"
    public static let urlScheme = "deadcenter"

    public static var containerDirectory: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(appGroup)", isDirectory: true)
    }

    public static var directory: URL {
        containerDirectory.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// One small JSON file per browser that has said hello: `<browser>.json` holding an `InboxPayload`.
    public static var presenceDirectory: URL {
        containerDirectory.appendingPathComponent("Presence", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Writes the payload atomically and returns the file's URL.
    /// `hello` payloads are written to the presence directory instead of the inbox.
    @discardableResult
    public static func deliver(_ payload: InboxPayload) throws -> URL {
        let fm = FileManager.default
        let data = try encoder.encode(payload)
        if payload.kind == .hello {
            try fm.createDirectory(at: presenceDirectory, withIntermediateDirectories: true)
            let name = (payload.browser ?? "unknown").lowercased().filter { $0.isLetter || $0.isNumber }
            let url = presenceDirectory.appendingPathComponent("\(name.isEmpty ? "unknown" : name).json")
            try data.write(to: url, options: .atomic)
            return url
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(payload.sentAt.timeIntervalSince1970 * 1000)
        let url = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Inbox files waiting to be read, oldest first.
    public static func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reads and removes an inbox file.
    public static func take(_ url: URL) throws -> InboxPayload {
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return try decoder.decode(InboxPayload.self, from: data)
    }

    /// Browsers that have said hello, with the time they last did.
    public static func presentBrowsers() -> [String: Date] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: presenceDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var result: [String: Date] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? decoder.decode(InboxPayload.self, from: data) else { continue }
            result[file.deletingPathExtension().lastPathComponent] = payload.sentAt
        }
        return result
    }

    /// `deadcenter://inbox?file=<name>` — opening it launches or wakes the app.
    public static func wakeURL(for file: URL) -> URL {
        var c = URLComponents()
        c.scheme = urlScheme
        c.host = "inbox"
        c.queryItems = [URLQueryItem(name: "file", value: file.lastPathComponent)]
        return c.url!
    }
}
