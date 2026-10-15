import AppKit

/// Dead Center lives in the menu bar, but while a real window is open (Settings, onboarding) it
/// should behave like an app: Dock icon, ⌘Tab, a menu bar with ⌘W/⌘Q/⌘V. Each window enters
/// when shown and leaves when closed; the app goes back to accessory once the last one is gone.
final class DockPresence {
    static let shared = DockPresence()

    private var owners = Set<ObjectIdentifier>()

    func enter(_ owner: AnyObject) {
        owners.insert(ObjectIdentifier(owner))
        installMainMenuIfNeeded()
        apply()
    }

    func leave(_ owner: AnyObject) {
        owners.remove(ObjectIdentifier(owner))
        apply()
    }

    private func apply() {
        let policy: NSApplication.ActivationPolicy = owners.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    /// A minimal standard menu, only if the app hasn't set one, so key equivalents work in our windows.
    private func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Dead Center", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(MenuActions.showSettings), keyEquivalent: ",")
        settings.target = MenuActions.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Dead Center", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Dead Center", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Dead Center", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}

private final class MenuActions: NSObject {
    static let shared = MenuActions()
    @objc func showSettings() { SettingsWindowController.shared.show() }
}
