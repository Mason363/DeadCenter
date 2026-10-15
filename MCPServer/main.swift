// dead-center-mcp: a Model Context Protocol server that lets AI assistants hand Dead Center something
// to read: text they wrote, a web page, or a document on this Mac. It speaks MCP over stdio, one
// JSON-RPC message per line, and delivers through the same shared inbox as the browser extensions,
// launching the app if it isn't running. stdout carries nothing but protocol messages.

import AppKit
import DCModel

@MainActor
enum Server {
    /// Protocol revisions this server speaks, newest first.
    static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// The assistant on the other end ("claude-ai", "claude-code"…), from `initialize`.
    static var client: String?

    static let instructions = """
        Dead Center is the user's speed reader on this Mac: it shows text one word at a time, or as a page \
        with the current word lit in red. Hand it prose the user is going to read (explanations, summaries, \
        study notes, articles, drafts), written as Markdown with a short title. Use it when the user asks, \
        or for a long piece of prose they'll read closely, and say in your reply that you sent it. \
        Use later: true when they want to save it for later. Don't send code, logs or data tables.
        """

    static func run() -> Never {
        // A client that goes away mid-reply shouldn't kill us with SIGPIPE; the write fails instead.
        signal(SIGPIPE, SIG_IGN)
        while let line = readLine() {
            guard line.contains(where: { !$0.isWhitespace }) else { continue }
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = message as? [Any] { batch.forEach(handle) } else { handle(message) }
        }
        exit(0)
    }

    private static func handle(_ message: Any) {
        guard let request = message as? [String: Any], let method = request["method"] as? String else {
            if let id = (message as? [String: Any])?["id"] { fail(id, code: -32600, "Invalid request") }
            return
        }
        // Notifications have no id and get no reply.
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            if let id { reply(id, initialize(params)) }
        case "ping":
            if let id { reply(id, [:]) }
        case "tools/list":
            if let id { reply(id, ["tools": Tools.list]) }
        case "tools/call":
            guard let id else { return }
            guard let name = params["name"] as? String, Tools.names.contains(name) else {
                return fail(id, code: -32602, "Unknown tool: \(params["name"] as? String ?? "none")")
            }
            reply(id, Tools.call(name, arguments: params["arguments"] as? [String: Any] ?? [:]))
        default:
            if let id, !method.hasPrefix("notifications/") { fail(id, code: -32601, "Method not found: \(method)") }
        }
    }

    private static func initialize(_ params: [String: Any]) -> [String: Any] {
        client = (params["clientInfo"] as? [String: Any])?["name"] as? String
        let requested = params["protocolVersion"] as? String ?? ""
        return [
            "protocolVersion": versions.contains(requested) ? requested : versions[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": AssistantServer.serverName, "title": "Dead Center", "version": version],
            "instructions": instructions,
        ]
    }

    private static var version: String {
        let app = Delivery.app.flatMap(Bundle.init(url:))
        return app?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private static func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func fail(_ id: Any, code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

// MARK: - Tools

@MainActor
enum Tools {
    static let names: Set<String> = ["read_text", "read_web_page", "read_file"]

    private static let later: [String: Any] = [
        "type": "boolean",
        "description": "Save it to the Dead Center library to read later, instead of opening it now.",
    ]

    static let list: [[String: Any]] = [
        [
            "name": "read_text",
            "title": "Read in Dead Center",
            "description": """
                Opens text in Dead Center, the user's speed reader, which shows it one word at a time or as a \
                page with the current word lit. Use it when the user asks to read something in Dead Center, or \
                for long-form prose they'll read closely: explanations, summaries, study notes, articles, \
                drafts. Write it as it should be read, with Markdown headings for sections; Markdown and LaTeX \
                are turned into clean prose. Not for code, data tables or short answers.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "What to read, as Markdown or plain text."],
                    "title": ["type": "string", "description": "A short title for the reading."],
                    "later": later,
                ],
                "required": ["text"],
            ],
            "annotations": annotations("Read in Dead Center", openWorld: false),
        ],
        [
            "name": "read_web_page",
            "title": "Read a web page in Dead Center",
            "description": """
                Opens a web article in Dead Center. Dead Center fetches the page itself and keeps just the \
                article: its text and pictures, without menus or ads.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The page's http or https address."],
                    "later": later,
                ],
                "required": ["url"],
            ],
            "annotations": annotations("Read a web page in Dead Center", openWorld: true),
        ],
        [
            "name": "read_file",
            "title": "Read a document in Dead Center",
            "description": """
                Opens a document on this Mac in Dead Center: PDF, EPUB, Word, Markdown, plain text, HTML, RTF, \
                or an image (its text is recognized). Recordings and videos are transcribed.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "The document's absolute path."],
                    "later": later,
                ],
                "required": ["path"],
            ],
            "annotations": annotations("Read a document in Dead Center", openWorld: false),
        ],
    ]

    private static func annotations(_ title: String, openWorld: Bool) -> [String: Any] {
        ["title": title, "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": openWorld]
    }

    static func call(_ name: String, arguments: [String: Any]) -> [String: Any] {
        let saveForLater = (arguments["later"] as? Bool ?? false) && Delivery.historyIsOn
        do {
            switch name {
            case "read_text":
                guard let text = arguments["text"] as? String, text.contains(where: { !$0.isWhitespace }) else {
                    return error("There's no text to read.")
                }
                guard text.utf8.count <= 20_000_000 else { return error("The text is too long (over 20 MB).") }
                let title = (arguments["title"] as? String).flatMap { $0.contains(where: { !$0.isWhitespace }) ? $0 : nil }
                try Delivery.send(InboxPayload(kind: .text, browser: Server.client, title: title, text: text, later: saveForLater))
                let name = "“\(title ?? Self.title(of: text))”"
                if saveForLater { return done("Saved \(name) to the Dead Center library for later.") }
                return done("Opened \(name) in Dead Center: \(Self.length(of: text)).")
            case "read_web_page":
                guard let string = arguments["url"] as? String, let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                    return error("That isn't a web address. Use an http or https URL.")
                }
                try Delivery.send(InboxPayload(kind: .page, browser: Server.client, url: url.absoluteString, later: saveForLater))
                return done(saveForLater ? "Saved \(url.absoluteString) to the Dead Center library for later."
                                         : "Opened \(url.absoluteString) in Dead Center.")
            default:
                guard let raw = arguments["path"] as? String, !raw.isEmpty else { return error("No path given.") }
                let path = (raw as NSString).expandingTildeInPath
                guard path.hasPrefix("/") else { return error("Give the document's absolute path.") }
                guard FileManager.default.fileExists(atPath: path) else { return error("There's no file at \(path).") }
                try Delivery.send(InboxPayload(kind: .file, browser: Server.client, path: path, later: saveForLater))
                let file = (path as NSString).lastPathComponent
                return done(saveForLater ? "Saved \(file) to the Dead Center library for later." : "Opened \(file) in Dead Center.")
            }
        } catch Delivery.Failure.noAnswer {
            return error("Dead Center didn't respond. Make sure it's installed and has been opened at least once.")
        } catch {
            return Self.error("Couldn't hand it to Dead Center: \(error.localizedDescription)")
        }
    }

    private static func done(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": false]
    }

    private static func error(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    /// The first line, without Markdown heading marks, as a stand-in title for the reply.
    private static func title(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { $0.contains(where: \.isLetter) } ?? ""
        let plain = line.drop { "#>*_ ".contains($0) }.trimmingCharacters(in: .whitespaces)
        return plain.count > 60 ? String(plain.prefix(57)) + "…" : plain
    }

    private static func length(of text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).count
        let wpm = max(Delivery.wordsPerMinute, 1)
        let minutes = max(1, Int((Double(words) / Double(wpm)).rounded()))
        return "\(words.formatted()) words, about \(minutes) min at \(wpm) wpm"
    }
}

// MARK: - Delivery

@MainActor
enum Delivery {
    enum Failure: Error { case noAnswer }

    /// The app's own settings, read the same way whether this runs inside the app or from its installed copy.
    private static func setting(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, "com.mason363.DeadCenter" as CFString)
    }

    static var wordsPerMinute: Int {
        let wpm = (setting("wpm") as? NSNumber)?.intValue ?? 0
        return wpm > 0 ? wpm : 350
    }

    /// With reading history off the app has no library to save into, and opens things right away.
    static var historyIsOn: Bool { (setting("rememberHistory") as? NSNumber)?.boolValue ?? true }

    /// The app to wake: the one this server is inside, or the one that installed this copy of it.
    static var app: URL? {
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app" { return app }
        }
        guard let path = try? String(contentsOf: AssistantServer.appRecord, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Drops the payload in the inbox, wakes the app, and waits for the app to take it.
    static func send(_ payload: InboxPayload) throws {
        let file = try Inbox.deliver(payload)
        wake(Inbox.wakeURL(for: file))
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: file.path) { return }
            usleep(50_000)
        }
        // Don't leave it to pop up whenever the app next starts.
        try? FileManager.default.removeItem(at: file)
        throw Failure.noAnswer
    }

    /// Opens `deadcenter://inbox?file=…` without bringing the app forward; the reader shows itself.
    private static func wake(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let done = DispatchSemaphore(value: 0)
        if let app {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, _ in done.signal() }
        } else {
            NSWorkspace.shared.open(url, configuration: configuration) { _, _ in done.signal() }
        }
        _ = done.wait(timeout: .now() + 10)
    }
}

Server.run()
