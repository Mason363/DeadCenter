import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads the selected text in another app: Accessibility first, then a careful ⌘C that
/// restores the clipboard afterwards.
enum SelectionGrabber {
    nonisolated enum Result: Sendable {
        case text(String)
        /// The app reported an empty selection.
        case none
        /// The app couldn't tell us.
        case unknown
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func selection(in app: NSRunningApplication, isBrowser: Bool) async -> Result {
        guard isTrusted else { return .unknown }
        let ax = await accessibilitySelection(pid: app.processIdentifier)
        switch ax {
        case .text:
            return ax
        case .none where !isBrowser:
            return .none
        case .none, .unknown:
            if let copied = await copySelection(), !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .text(copied)
            }
            return ax
        }
    }

    /// Accessibility calls can wait on a busy app, so they run off the main thread.
    @concurrent private nonisolated static func accessibilitySelection(pid: pid_t) async -> Result {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.4)
        // Chromium and Electron apps only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        let focusedElement = focused as! AXUIElement

        var selected: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selected)
        guard result == .success else { return .unknown }
        guard let text = selected as? String else { return .unknown }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .text(text)
    }

    /// The file behind the focused window (Preview, TextEdit, Pages, Word…), if the app exposes it.
    static func documentURL(in app: NSRunningApplication) async -> URL? {
        guard isTrusted else { return nil }
        return await documentURL(pid: app.processIdentifier)
    }

    @concurrent private nonisolated static func documentURL(pid: pid_t) async -> URL? {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.4)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &document) == .success,
              let path = document as? String, let url = URL(string: path), url.isFileURL else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Copy fallback

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        await waitForModifierRelease()
        postCommandC()

        let deadline = Date().addingTimeInterval(0.45)
        while pasteboard.changeCount == before, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard pasteboard.changeCount != before else {
            // A slow app may still copy after we stop waiting; put the clipboard back if it does.
            Task { await restoreAfterLateCopy(saved, since: before) }
            return nil
        }
        var text = string(on: pasteboard)
        // Some apps announce the copy a moment before the text is there.
        for _ in 0..<6 where text == nil {
            try? await Task.sleep(for: .milliseconds(25))
            text = string(on: pasteboard)
        }
        restore(saved, to: pasteboard)
        return text
    }

    private static func string(on pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string)
            ?? pasteboard.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
    }

    private static func restoreAfterLateCopy(_ saved: [[NSPasteboard.PasteboardType: Data]], since before: Int) async {
        let pasteboard = NSPasteboard.general
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
            guard pasteboard.changeCount != before else { continue }
            // Only our ⌘C landing; anything later is the person copying something new.
            if pasteboard.changeCount == before + 1 { restore(saved, to: pasteboard) }
            return
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type] = data }
            }
            return types
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            // Ask clipboard managers to ignore this round trip (nspasteboard.org convention).
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            return item
        }
        pasteboard.writeObjects(restored)
    }

    /// The hotkey's modifiers are usually still held; let them go before synthesizing ⌘C.
    private static func waitForModifierRelease() async {
        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskAlternate, .maskShift, .maskControl]).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = keyCode(for: "c") ?? 8
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The key code that types `character` in the current keyboard layout (so Dvorak, AZERTY… work).
    private static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, chars.count, &length, &chars)
                if status == noErr, length == 1, Character(UnicodeScalar(chars[0])!) == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
