import AppKit
import DCModel
import os

/// Connects AI assistants to Dead Center's MCP server, so they can hand it something to read.
@Observable
final class AssistantSetup {
    static let shared = AssistantSetup()

    enum Client: String, CaseIterable, Identifiable {
        case claudeDesktop, claudeCode
        var id: Self { self }

        var name: String {
            switch self {
            case .claudeDesktop: "Claude"
            case .claudeCode: "Claude Code"
            }
        }
    }

    enum Status: Equatable {
        case missing
        case notConnected
        case connected
        case working
        /// Connected; the app needs a restart to pick it up.
        case restartNeeded
        case failed(String)
    }

    private(set) var statuses: [Client: Status] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.mason363.DeadCenter", category: "assistants")

    // MARK: - Status

    func refresh() {
        for client in Client.allCases where !isBusy(client) {
            statuses[client] = currentStatus(of: client)
        }
    }

    private func isBusy(_ client: Client) -> Bool {
        switch statuses[client] {
        case .working, .restartNeeded, .failed: true
        default: false
        }
    }

    private func currentStatus(of client: Client) -> Status {
        switch client {
        case .claudeDesktop:
            guard Self.claudeDesktopApp != nil else { return .missing }
            let servers = (try? Self.readJSON(Self.claudeDesktopConfig))?["mcpServers"] as? [String: Any]
            return servers?[AssistantServer.serverName] == nil ? .notConnected : .connected
        case .claudeCode:
            guard Self.claudeCodeCLI != nil else { return .missing }
            let servers = (try? Self.readJSON(Self.claudeCodeConfig))?["mcpServers"] as? [String: Any]
            return servers?[AssistantServer.serverName] == nil ? .notConnected : .connected
        }
    }

    // MARK: - Connecting

    func connect(_ client: Client) {
        statuses[client] = .working
        Task {
            do {
                try installServer()
                switch client {
                case .claudeDesktop:
                    try Self.updateClaudeDesktopConfig(adding: true)
                    statuses[client] = Self.isRunning(Self.claudeDesktopBundleID) ? .restartNeeded : .connected
                case .claudeCode:
                    let cli = try Self.requireClaudeCode()
                    try await Self.run(cli, ["mcp", "remove", "--scope", "user", AssistantServer.serverName], allowFailure: true)
                    try await Self.run(cli, ["mcp", "add", "--scope", "user", AssistantServer.serverName, "--",
                                             AssistantServer.executable.path])
                    statuses[client] = .connected
                }
            } catch {
                log.error("Connecting \(client.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                statuses[client] = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect(_ client: Client) {
        statuses[client] = .working
        Task {
            do {
                switch client {
                case .claudeDesktop:
                    try Self.updateClaudeDesktopConfig(adding: false)
                case .claudeCode:
                    try await Self.run(try Self.requireClaudeCode(), ["mcp", "remove", "--scope", "user", AssistantServer.serverName],
                                       allowFailure: true)
                }
                statuses[client] = nil
                refresh()
            } catch {
                statuses[client] = .failed(error.localizedDescription)
            }
        }
    }

    /// Clears a finished or failed attempt so the row shows the plain status again.
    func dismiss(_ client: Client) {
        statuses[client] = nil
        refresh()
    }

    // MARK: - The server

    /// The server command other apps can run.
    var serverPath: String { AssistantServer.executable.path }

    /// Copies the server out of the app bundle (so assistants' settings survive the app moving or
    /// updating) and records which app it should wake.
    func installServer() throws {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: AssistantServer.name) else {
            throw SetupError("The assistant server is missing from Dead Center. Try reinstalling the app.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: AssistantServer.directory, withIntermediateDirectories: true)
        let target = AssistantServer.executable
        if !fm.contentsEqual(atPath: bundled.path, andPath: target.path) {
            let staged = AssistantServer.directory.appendingPathComponent(".\(AssistantServer.name)-\(UUID().uuidString)")
            try fm.copyItem(at: bundled, to: staged)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        }
        try Bundle.main.bundleURL.path.write(to: AssistantServer.appRecord, atomically: true, encoding: .utf8)
    }

    /// At launch: once any assistant is connected, keep its server current with this copy of the app.
    func refreshInstalledServer() {
        guard FileManager.default.fileExists(atPath: AssistantServer.executable.path) else { return }
        do { try installServer() } catch { log.error("Refreshing the assistant server failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - Claude

    private static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    static var claudeDesktopApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeDesktopBundleID)
    }

    private static var claudeDesktopConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    private static var claudeCodeConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// Adds or removes Dead Center in Claude's settings file, leaving everything else as it is.
    private static func updateClaudeDesktopConfig(adding: Bool) throws {
        let url = claudeDesktopConfig
        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            // Never overwrite a file we can't read.
            guard let existing = try? readJSON(url) else {
                throw SetupError("Claude's settings file couldn't be read, so it was left alone.")
            }
            config = existing
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        if adding {
            servers[AssistantServer.serverName] = ["command": AssistantServer.executable.path, "args": [String]()]
        } else {
            servers[AssistantServer.serverName] = nil
        }
        config["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SetupError("Not a settings file.")
        }
        return object
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// The `claude` command, wherever it was installed.
    static var claudeCodeCLI: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    private static func requireClaudeCode() throws -> URL {
        guard let cli = claudeCodeCLI else { throw SetupError("Claude Code isn't installed.") }
        return cli
    }

    /// Runs the `claude` command off the main thread.
    @concurrent private nonisolated static func run(_ cli: URL, _ arguments: [String], allowFailure: Bool = false) async throws {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Claude Code may be a script that needs node from the usual places.
        environment["PATH"] = [cli.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                               environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || allowFailure else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SetupError(message?.isEmpty == false ? message! : "Claude Code couldn't add the server.")
        }
    }
}

nonisolated struct SetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
