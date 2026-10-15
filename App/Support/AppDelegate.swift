import AppKit
import KeyboardShortcuts
import DCModel
import DCEngine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let services = ServicesProvider()
    /// Opened by double-clicking the app (not at login, and not to open a file or link).
    private var launchedByUser = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isOpenApp = event?.eventID == AEEventID(kAEOpenApplication)
        let isLoginItem = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
        launchedByUser = isOpenApp && !isLoginItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        TranscriptionHooks.install()
        statusItem = StatusItemController()

        KeyboardShortcuts.onKeyDown(for: .read) { InputRouter.shared.readSmart() }
        KeyboardShortcuts.onKeyDown(for: .readClipboard) { ReadingCoordinator.shared.readClipboard() }

        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        InboxWatcher.shared.start()
        BrowserIntegration.shared.installNativeHosts()
        LibraryStore.shared.prune()
        AppHooks.didFinishLaunching()
        _ = Updater.shared
        AssistantSetup.shared.refreshInstalledServer()
        warmUp()

        if !Preferences.shared.hasCompletedOnboarding {
            OnboardingWindowController.shared.show()
        } else if launchedByUser {
            LibraryWindowController.shared.show()
        }
    }

    /// A main menu so standard editing keys (⌘C, ⌘V, ⌘Z, ⌘A) work in text fields and the page editor.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Dead Center", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Dead Center", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Dead Center", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        for (title, key, modifiers, action) in [
            ("New Text", "n", NSEvent.ModifierFlags.command, #selector(menuNewText)),
            ("Open…", "o", .command, #selector(menuOpen)),
            ("Read Clipboard", "v", [.command, .shift], #selector(menuReadClipboard)),
        ] as [(String, String, NSEvent.ModifierFlags, Selector)] {
            let item = file.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
        }
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let library = windowMenu.addItem(withTitle: "Dead Center", action: #selector(openLibrary), keyEquivalent: "0")
        library.target = self
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openLibrary() { LibraryWindowController.shared.show() }
    @objc private func menuNewText() { ReadingCoordinator.shared.compose() }
    @objc private func menuOpen() { ReadingCoordinator.shared.presentOpenPanel() }
    @objc private func menuReadClipboard() { ReadingCoordinator.shared.readClipboard() }

    /// Loads language models, fonts and the reader window ahead of the first hotkey press.
    private func warmUp() {
        _ = ReadingCoordinator.shared
        Task.detached(priority: .utility) {
            _ = Tokenizer().tokenize([.paragraph("Warm up the tokenizer. 准备好了。準備できました。")])
        }
        _ = Typesetter.typeset("Ready", pivot: 1, style: WordStyle(
            font: Preferences.shared.font(size: 60), pivotFont: Preferences.shared.font(size: 60),
            text: .white, pivot: .red))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        URLRouter.handle(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        LibraryWindowController.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ReadingCoordinator.shared.saveProgress()
        LibraryStore.shared.save()
    }
}

/// Launch-time setup for optional pieces (updates, transcription) that live in other files.
enum AppHooks {
    static var launchActions: [() -> Void] = []

    static func didFinishLaunching() {
        launchActions.forEach { $0() }
    }
}
