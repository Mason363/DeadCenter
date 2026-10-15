import AppKit
import DCModel
import os

/// What the browser extension sends, turned into an `InboxPayload` and handed to the app.
/// Shared by the native-messaging bridge (Chrome, Firefox, Zen) and the Safari app extension.
enum IncomingMessage {
    enum Failure: Error, CustomStringConvertible {
        case notAnObject
        case unknownKind(String?)
        case nothingToRead

        var description: String {
            switch self {
            case .notAnObject: "The message isn't a JSON object."
            case .unknownKind(let kind): "Unknown message kind \(kind.map { "\"\($0)\"" } ?? "(none)")."
            case .nothingToRead: "The message has nothing to read."
            }
        }
    }

    static let log = Logger(subsystem: "com.mason363.DeadCenter", category: "browser")

    /// Builds a payload from a decoded JSON object, forgiving about missing or oddly typed fields.
    /// A missing or unreadable `sentAt` becomes now; `browser` falls back to `defaultBrowser`.
    static func payload(from object: Any, defaultBrowser: String?) throws -> InboxPayload {
        guard let fields = object as? [String: Any] else { throw Failure.notAnObject }
        func string(_ key: String) -> String? {
            guard let value = fields[key] as? String, !value.isEmpty else { return nil }
            return value
        }

        let kind: InboxPayload.Kind
        switch string("kind")?.lowercased() {
        case "page", "link": kind = .page
        case "selection": kind = .selection
        case "hello": kind = .hello
        case let other: throw Failure.unknownKind(other)
        }

        let payload = InboxPayload(
            kind: kind,
            browser: string("browser")?.lowercased() ?? defaultBrowser,
            title: string("title"),
            url: string("url"),
            html: string("html"),
            text: string("text"),
            sentAt: date(fields["sentAt"]) ?? Date())

        let hasText = [payload.html, payload.text].contains { $0?.contains(where: { !$0.isWhitespace }) == true }
        switch kind {
        case .page where !hasText && payload.url == nil, .selection where !hasText:
            throw Failure.nothingToRead
        default:
            return payload
        }
    }

    /// Drops the payload in the shared inbox and records the browser as connected.
    /// Returns the inbox file for anything other than a hello.
    @discardableResult
    static func deliver(_ payload: InboxPayload) throws -> URL? {
        var presence = payload
        presence.kind = .hello
        presence.title = nil
        presence.url = nil
        presence.html = nil
        presence.text = nil
        try Inbox.deliver(presence)
        guard payload.kind != .hello else { return nil }
        return try Inbox.deliver(payload)
    }

    /// Opens `deadcenter://inbox?file=…` so the app launches, or wakes, and reads the file.
    /// Prefers the app bundle this executable lives in, so a stale copy elsewhere never answers.
    static func wakeApp(for file: URL, preferring app: URL?) {
        let url = Inbox.wakeURL(for: file)
        let done = DispatchSemaphore(value: 0)
        let activating: @Sendable () -> NSWorkspace.OpenConfiguration = {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            return configuration
        }
        let openByScheme: @Sendable () -> Void = {
            NSWorkspace.shared.open(url, configuration: activating()) { _, error in
                if let error { log.error("Couldn't wake Dead Center: \(error.localizedDescription, privacy: .public)") }
                done.signal()
            }
        }

        if let app {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: activating()) { _, error in
                guard let error else {
                    done.signal()
                    return
                }
                log.notice("Opening \(app.path, privacy: .public) failed (\(error.localizedDescription, privacy: .public)); trying the URL scheme")
                openByScheme()
            }
        } else {
            openByScheme()
        }
        if done.wait(timeout: .now() + 10) == .timedOut {
            log.error("Timed out waking Dead Center")
        }
    }

    /// The `.app` that contains `url`, `levels` directories up, if there is one.
    static func enclosingApp(of url: URL, levels: Int) -> URL? {
        var app = url.resolvingSymlinksInPath()
        for _ in 0..<levels { app.deleteLastPathComponent() }
        return app.pathExtension == "app" ? app : nil
    }

    private static func date(_ value: Any?) -> Date? {
        switch value {
        case let string as String:
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: string)
        case let number as NSNumber:
            // Milliseconds (JavaScript's Date.now()) or seconds since 1970.
            let value = number.doubleValue
            return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
        default:
            return nil
        }
    }
}
