import Foundation

/// The MCP server AI assistants launch to hand Dead Center something to read. The app installs a
/// copy outside its bundle, so assistants' settings keep working when the app moves or updates.
public enum AssistantServer {
    public static let name = "dead-center-mcp"
    /// The name assistants list the server under.
    public static let serverName = "dead-center"

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dead Center/Assistants", isDirectory: true)
    }

    public static var executable: URL { directory.appendingPathComponent(name) }

    /// Holds the path of the app that installed the server; that's the app the server wakes.
    public static var appRecord: URL { directory.appendingPathComponent("app-path") }
}
