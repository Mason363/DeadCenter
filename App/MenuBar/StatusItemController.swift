import AppKit
import KeyboardShortcuts
import DCModel

/// The menu bar icon: a native menu, and a drop target for text, links and files.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "smallcircle.filled.circle", accessibilityDescription: "Dead Center")
            image?.isTemplate = true
            image?.accessibilityDescription = "Dead Center"
            button.image = image
            button.registerForDraggedTypes([.fileURL, .URL, .string, .html, .rtf, .png, .tiff])
            StatusDrop.handler = { pasteboard in
                switch PasteboardReader.content(of: pasteboard, origin: .text) {
                case .files(let urls): ReadingCoordinator.shared.open(urls)
                case .request(let request): ReadingCoordinator.shared.read(request)
                case nil: return false
                }
                return true
            }
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(NSMenuItem(title: "Open Dead Center", action: #selector(openLibrary), keyEquivalent: "0"))
        menu.addItem(.separator())

        let read = NSMenuItem(title: "Read Selection", action: #selector(readSmart), keyEquivalent: "")
        read.setShortcut(for: .read)
        menu.addItem(read)

        let clipboard = NSMenuItem(title: "Read Clipboard", action: #selector(readClipboard), keyEquivalent: "")
        clipboard.setShortcut(for: .readClipboard)
        menu.addItem(clipboard)

        menu.addItem(NSMenuItem(title: "Open File…", action: #selector(openFile), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "New Text…", action: #selector(compose), keyEquivalent: "n"))
        if Preferences.shared.pageScanning {
            menu.addItem(NSMenuItem(title: "Scan Pages…", action: #selector(scanPages), keyEquivalent: ""))
        }
        for extra in MenuExtras.items() { menu.addItem(extra) }

        let recents = LibraryStore.shared.recents(limit: 6)
        if !recents.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recent"))
            for entry in recents {
                let title = entry.title.isEmpty ? "Untitled" : entry.title
                let item = NSMenuItem(title: Self.truncated(title), action: #selector(resume(_:)), keyEquivalent: "")
                item.representedObject = entry.id
                item.toolTip = title
                item.image = NSImage(systemSymbolName: Self.symbol(for: entry.origin), accessibilityDescription: nil)
                item.badge = NSMenuItemBadge(string: entry.finished ? "Done" : "\(Int((entry.progress * 100).rounded()))%")
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Dead Center", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
    }

    private static func truncated(_ title: String) -> String {
        title.count > 44 ? String(title.prefix(42)) + "…" : title
    }

    private static func symbol(for origin: DocumentOrigin) -> String {
        switch origin {
        case .file(let url):
            switch url.pathExtension.lowercased() {
            case "pdf": "doc.richtext"
            case "epub": "book"
            case "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp": "photo"
            default: "doc.text"
            }
        case .web: "globe"
        case .clipboard: "doc.on.clipboard"
        case .selection: "text.cursor"
        case .text: "text.alignleft"
        }
    }

    @objc private func readSmart() {
        // The menu has focus right now; give it a beat to close so the previous app is frontmost again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { InputRouter.shared.readSmart() }
    }

    @objc private func readClipboard() { ReadingCoordinator.shared.readClipboard() }
    @objc private func openFile() { ReadingCoordinator.shared.presentOpenPanel() }
    @objc private func compose() { ReadingCoordinator.shared.compose() }
    @objc private func scanPages() { LibraryWindowController.shared.scan() }
    @objc private func openLibrary() { LibraryWindowController.shared.show() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func resume(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = LibraryStore.shared.entry(id: id) else { return }
        ReadingCoordinator.shared.resume(entry)
    }
}

/// Additional menu items contributed by optional features (transcription).
enum MenuExtras {
    static var items: () -> [NSMenuItem] = { [] }
}

/// Drag-and-drop onto the status item's button.
enum StatusDrop {
    static var handler: ((NSPasteboard) -> Bool)?
}

extension NSStatusBarButton {
    open override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard StatusDrop.handler != nil else { return [] }
        highlight(true)
        return .copy
    }

    open override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        highlight(false)
    }

    open override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlight(false)
        return StatusDrop.handler?(sender.draggingPasteboard) ?? false
    }
}
