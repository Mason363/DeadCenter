import AppKit
import DCModel
import SafariServices
import os

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

    /// The browser's main bundle identifier, used to find out whether it's installed.
    var bundleIdentifier: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .zen: "app.zen-browser.zen"
        case .safari: "com.apple.Safari"
        }
    }

    /// Every app that counts as this browser, including its beta channels.
    var bundleIdentifiers: Set<String> {
        switch self {
        case .chrome: ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"]
        case .zen: ["app.zen-browser.zen"]
        case .safari: ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
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
///
/// The extension (WebExtension/, built per browser by Scripts/build-extensions.sh) talks to the app through
/// the shared `Inbox`: Chrome, Firefox and Zen launch `Contents/MacOS/dead-center-bridge` over native
/// messaging, Safari goes through the bundled app extension. Both drop an `InboxPayload` file and open
/// `deadcenter://inbox?file=…`.
///
/// The extension's `read-page` command is bound to ⌃⇧. (Control-Shift-Period, `MacCtrl+Shift+Period` in
/// the manifest). `requestPageFromExtension(in:)` synthesizes exactly that keystroke, so the two must stay
/// in sync. A user who rebinds the command in the browser breaks that path; the app should then fall back
/// to `frontTabURL(of:)` when nothing arrives in the inbox.
final class BrowserIntegration {
    static let shared = BrowserIntegration()

    /// Native-messaging host name; the extension calls `runtime.sendNativeMessage` with it.
    static let nativeHostName = "com.mason363.deadcenter"
    /// Chrome derives this from the public key in the Chrome manifest (see Scripts/build-extensions.sh).
    static let chromeExtensionID = "ghjobggknlahpjlmhbkmphnbejehmlai"
    /// The add-on ID in the Firefox/Zen manifest.
    static let geckoExtensionID = "deadcenter@mason363.com"
    static let safariExtensionIdentifier = "com.mason363.DeadCenter.SafariExtension"
    /// kVK_ANSI_Period: the extension's read-page command is ⌃⇧ and this key.
    static let readPageKeyCode: CGKeyCode = 47

    private let log = Logger(subsystem: "com.mason363.DeadCenter", category: "browser")

    // MARK: Native-messaging hosts

    /// Writes/refreshes native-messaging host manifests for every supported browser. Idempotent; called at launch.
    ///
    /// Chromium-family browsers each read `<their data dir>/NativeMessagingHosts`. Firefox and Zen both read
    /// `~/Library/Application Support/Mozilla/NativeMessagingHosts` (Zen keeps Gecko's hard-coded "Mozilla"
    /// folder for native manifests even though its profiles live in `…/zen`).
    func installNativeHosts() {
        guard let bridge = Bundle.main.url(forAuxiliaryExecutable: "dead-center-bridge") else {
            log.error("dead-center-bridge is missing from the app bundle")
            return
        }
        // A translocated or disk-image copy moves or disappears; manifests pointing there would break.
        let bundle = Bundle.main.bundleURL
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        guard !bundle.path.contains("/AppTranslocation/"), !readOnly else {
            log.notice("Not installing native-messaging hosts from a temporary location: \(bundle.path, privacy: .public)")
            return
        }

        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        for location in Self.hostLocations {
            guard location.evidence.contains(where: { fm.fileExists(atPath: support.appending(path: $0).path) }) else { continue }
            var manifest: [String: Any] = [
                "name": Self.nativeHostName,
                "description": "Dead Center",
                "path": bridge.path,
                "type": "stdio",
            ]
            switch location.family {
            case .chromium: manifest["allowed_origins"] = ["chrome-extension://\(Self.chromeExtensionID)/"]
            case .gecko: manifest["allowed_extensions"] = [Self.geckoExtensionID]
            }
            let directory = support.appending(path: location.directory, directoryHint: .isDirectory)
            let file = directory.appending(path: "\(Self.nativeHostName).json")
            do {
                var data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                data.append(0x0A)
                if (try? Data(contentsOf: file)) == data { continue }
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                log.info("Installed native-messaging host at \(file.path, privacy: .public)")
            } catch {
                log.error("Couldn't write \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private enum HostFamily { case chromium, gecko }

    private struct HostLocation {
        /// Relative to ~/Library/Application Support.
        let directory: String
        /// Folders (same base) whose existence means the browser is, or was, used here.
        let evidence: [String]
        let family: HostFamily

        static func chromium(_ dataDirectory: String) -> HostLocation {
            HostLocation(directory: "\(dataDirectory)/NativeMessagingHosts", evidence: [dataDirectory], family: .chromium)
        }
    }

    private static let hostLocations: [HostLocation] = [
        .chromium("Google/Chrome"),
        .chromium("Google/Chrome Beta"),
        .chromium("Google/Chrome Dev"),
        .chromium("Google/Chrome Canary"),
        .chromium("Chromium"),
        .chromium("BraveSoftware/Brave-Browser"),
        .chromium("BraveSoftware/Brave-Browser-Beta"),
        .chromium("BraveSoftware/Brave-Browser-Nightly"),
        .chromium("Microsoft Edge"),
        .chromium("Microsoft Edge Beta"),
        .chromium("Microsoft Edge Dev"),
        .chromium("Microsoft Edge Canary"),
        .chromium("Arc/User Data"),
        .chromium("Vivaldi"),
        HostLocation(directory: "Mozilla/NativeMessagingHosts",
                     evidence: ["Mozilla", "Firefox", "zen", "Floorp", "librewolf", "Waterfox"],
                     family: .gecko),
    ]

    // MARK: Extension status and install

    func status(for browser: BrowserKind) -> BrowserExtensionStatus {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil else {
            return .browserMissing
        }
        if let date = Inbox.presentBrowsers()[browser.rawValue] { return .connected(date) }
        return .notConnected
    }

    /// The copy of the extension shipped inside the app: the unpacked Chrome folder or the Zen/Firefox `.xpi`.
    func bundledExtension(for browser: BrowserKind) -> URL? {
        let extensions = Bundle.main.resourceURL?.appending(path: "Extensions", directoryHint: .isDirectory)
        let url: URL? = switch browser {
        case .chrome: extensions?.appending(path: "Chrome", directoryHint: .isDirectory)
        case .zen: extensions?.appending(path: "DeadCenter.xpi")
        case .safari: nil
        }
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Opens whatever gets the user to the install step for that browser's extension.
    ///
    /// - Chrome: opens chrome://extensions in Chrome and reveals the bundled unpacked extension in Finder.
    ///   The user turns on Developer mode and drags the folder onto the page (or uses Load unpacked).
    /// - Zen: opens the bundled `.xpi` with Zen. Release builds of Firefox-family browsers only install signed
    ///   add-ons permanently; Zen honors `xpinstall.signatures.required = false` in about:config, and
    ///   about:debugging ▸ Load Temporary Add-on works until the browser quits.
    /// - Safari: opens Safari ▸ Settings ▸ Extensions on Dead Center's extension.
    func openInstallInstructions(for browser: BrowserKind) {
        switch browser {
        case .chrome:
            let folder = bundledExtension(for: .chrome)
            let script = """
                tell application id "\(BrowserKind.chrome.bundleIdentifier)"
                    activate
                    if (count of windows) is 0 then make new window
                    tell front window to make new tab with properties {URL:"chrome://extensions"}
                end tell
                """
            Self.runAppleScript(script) { [log] result in
                if result == nil {
                    log.notice("Couldn't open chrome://extensions through Apple Events")
                    if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserKind.chrome.bundleIdentifier) {
                        NSWorkspace.shared.openApplication(at: chrome, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }

        case .zen:
            guard let zen = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserKind.zen.bundleIdentifier) else { return }
            if let xpi = bundledExtension(for: .zen) {
                NSWorkspace.shared.open([xpi], withApplicationAt: zen, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.openApplication(at: zen, configuration: NSWorkspace.OpenConfiguration())
            }

        case .safari:
            let safariID = BrowserKind.safari.bundleIdentifier
            SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.safariExtensionIdentifier) { @Sendable [log] error in
                guard let error else { return }
                // Safari hasn't seen the extension yet (the app must have run once), or Safari refused.
                log.error("Couldn't show the Safari extension: \(error.localizedDescription, privacy: .public)")
                if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariID) {
                    NSWorkspace.shared.openApplication(at: safari, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }

    /// Whether Dead Center's Safari extension is turned on in Safari ▸ Settings ▸ Extensions; nil if Safari can't say.
    func isSafariExtensionEnabled() async -> Bool? {
        await withCheckedContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Self.safariExtensionIdentifier) { @Sendable state, _ in
                continuation.resume(returning: state?.isEnabled)
            }
        }
    }

    // MARK: Running browsers

    /// Whether this running app is a web browser Dead Center knows how to talk to.
    func isBrowser(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map { Self.knownBrowsers[$0] != nil } ?? false
    }

    /// The browser Dead Center ships an extension for that this app is, if any.
    func browserKind(for app: NSRunningApplication) -> BrowserKind? {
        guard let id = app.bundleIdentifier else { return nil }
        return BrowserKind.allCases.first { $0.bundleIdentifiers.contains(id) }
    }

    /// Whether the app may post synthetic keystrokes (Privacy & Security ▸ Accessibility), which
    /// `requestPageFromExtension(in:)` needs.
    var canPostKeystrokes: Bool { CGPreflightPostEventAccess() }

    /// Asks for the permission behind `canPostKeystrokes`; macOS shows its prompt once.
    @discardableResult
    func requestKeystrokePermission() -> Bool { CGRequestPostEventAccess() }

    /// If the extension is known to be present in this browser, asks it to send the current page and returns true.
    /// The page arrives later through the Inbox.
    ///
    /// Waits (briefly) for the user to let go of the hotkey's modifiers, then sends ⌃⇧. to the browser.
    func requestPageFromExtension(in app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, let known = Self.knownBrowsers[id], !known.presence.isEmpty else { return false }
        let present = Inbox.presentBrowsers()
        guard known.presence.contains(where: { present[$0] != nil }) else { return false }
        guard canPostKeystrokes else {
            log.notice("Can't post the read-page shortcut without Accessibility access")
            return false
        }
        let pid = app.processIdentifier
        Task {
            let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
            let deadline = ContinuousClock.now + .milliseconds(400)
            while !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let source = CGEventSource(stateID: .hidSystemState)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: Self.readPageKeyCode, keyDown: keyDown) else { continue }
                event.flags = [.maskControl, .maskShift]
                event.postToPid(pid)
                if keyDown { try? await Task.sleep(for: .milliseconds(8)) }
            }
        }
        return true
    }

    /// The front tab's URL via Apple Events (Safari and Chromium-family browsers), or nil.
    /// Blocks for at most about 1.5 seconds; nil on error, timeout, or when Automation access is denied.
    func frontTabURL(of app: NSRunningApplication) async -> URL? {
        guard !app.isTerminated, let id = app.bundleIdentifier, let style = Self.knownBrowsers[id]?.tabScript else { return nil }
        let tab = style == .safari ? "current tab" : "active tab"
        let script = """
            with timeout of 2 seconds
                tell application id "\(id)"
                    if (count of windows) is 0 then return ""
                    return URL of \(tab) of front window
                end tell
            end timeout
            """
        guard let string = await Self.runAppleScript(script, timeout: 1.5), !string.isEmpty,
              let url = URL(string: string), url.scheme != nil else { return nil }
        return url
    }

    private enum TabScript { case safari, chromium }

    private struct KnownBrowser {
        /// The `browser` names this browser's extension reports in hello/presence files.
        var presence: [String]
        var tabScript: TabScript?
    }

    private static let knownBrowsers: [String: KnownBrowser] = {
        var table: [String: KnownBrowser] = [:]
        func add(_ ids: [String], _ presence: [String], _ script: TabScript?) {
            for id in ids { table[id] = KnownBrowser(presence: presence, tabScript: script) }
        }
        add(["com.apple.Safari", "com.apple.SafariTechnologyPreview"], ["safari"], .safari)
        add(["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"], ["chrome"], .chromium)
        add(["org.chromium.Chromium"], ["chromium", "chrome"], .chromium)
        add(["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"], ["brave"], .chromium)
        add(["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"], ["edge"], .chromium)
        // Arc's extension reports "arc" once it has read a page (Arc is only detectable from inside a page).
        add(["company.thebrowser.Browser"], ["arc"], .chromium)
        add(["com.vivaldi.Vivaldi"], ["vivaldi", "chromium"], .chromium)
        add(["com.operasoftware.Opera", "com.operasoftware.OperaGX"], ["opera"], nil)
        add(["app.zen-browser.zen"], ["zen"], nil)
        add(["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"], ["firefox"], nil)
        add(["org.mozilla.librewolf", "io.gitlab.librewolf-community"], ["librewolf"], nil)
        add(["net.waterfox.waterfox"], ["waterfox"], nil)
        add(["one.ablaze.floorp"], ["floorp"], nil)
        add(["com.kagi.kagimacOS"], [], .safari)
        add(["company.thebrowser.dia", "com.duckduckgo.macos.browser", "org.torproject.torbrowser"], [], nil)
        return table
    }()

    // MARK: Apple Events

    private nonisolated static let scriptQueue = DispatchQueue(label: "com.mason363.DeadCenter.applescript")

    /// Runs an AppleScript on a background queue and waits up to `timeout` for its string result.
    /// Runs an AppleScript on the script queue without blocking the caller; nil after `timeout`.
    private nonisolated static func runAppleScript(_ source: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (String?) -> Void = { value in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            scriptQueue.async { finish(execute(source)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Runs an AppleScript on a background queue and calls back on the main actor with its result.
    private static func runAppleScript(_ source: String, completion: @escaping @MainActor (String?) -> Void) {
        scriptQueue.async {
            let output = execute(source)
            Task { @MainActor in completion(output) }
        }
    }

    private nonisolated static func execute(_ source: String) -> String? {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? (output?.stringValue ?? "") : nil
    }
}
