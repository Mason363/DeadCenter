import AppKit

/// Browsers Dead Center ships an extension for.
enum BrowserKind: String, CaseIterable, Identifiable {
    case chrome, zen, safari
    var id: Self { self }
    var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .zen: "Zen"
        case .safari: "Safari"
        }
    }
}

enum BrowserExtensionStatus: Equatable {
    /// The browser itself isn't installed.
    case browserMissing
    /// Browser installed, extension has never said hello.
    case notConnected
    /// Extension said hello at this time.
    case connected(Date)
}

/// Everything the app knows about browsers: native-messaging host install, extension presence,
/// triggering the extension from the global hotkey, and reading the front tab's URL as a fallback.
final class BrowserIntegration {
    static let shared = BrowserIntegration()

    /// Writes/refreshes native-messaging host manifests for every supported browser. Idempotent; called at launch.
    func installNativeHosts() {}

    func status(for browser: BrowserKind) -> BrowserExtensionStatus { .notConnected }

    /// Opens whatever gets the user to the install step for that browser's extension.
    func openInstallInstructions(for browser: BrowserKind) {}

    /// Whether this running app is a web browser Dead Center knows how to talk to.
    func isBrowser(_ app: NSRunningApplication) -> Bool { false }

    /// If the extension is known to be present in this browser, asks it to send the current page and returns true.
    /// The page arrives later through the Inbox.
    func requestPageFromExtension(in app: NSRunningApplication) -> Bool { false }

    /// The front tab's URL via Apple Events (Safari and Chromium-family browsers), or nil.
    func frontTabURL(of app: NSRunningApplication) -> URL? { nil }
}
