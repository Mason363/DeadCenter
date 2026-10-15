import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The transcript window: borderless-looking, in the reader's palette, remembering its frame.
final class TranscriptWindowController: NSWindowController, NSWindowDelegate {
    private unowned let controller: TranscriptionController
    private let prefs = Preferences.shared
    private let transcriptionPrefs = TranscriptionPreferences.shared

    init(controller: TranscriptionController) {
        self.controller = controller
        let window = TranscriptWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: true)
        window.title = "Transcript"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 380, height: 260)
        window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        window.contentView = NSHostingView(rootView: TranscriptView(controller: controller))
        super.init(window: window)
        window.delegate = self
        window.transcription = controller
        window.center()
        window.setFrameAutosaveName("TranscriptWindow")
        observePreferences()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        guard let window else { return }
        let opening = !window.isVisible
        if opening { DockPresence.shared.enter(self) }
        applyStyle()
        NSApp.activate()
        guard opening, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.shared.leave(self)
        controller.windowDidClose()
    }

    // MARK: - Appearance

    private func applyStyle() {
        guard let window else { return }
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = prefs.palette(systemIsDark: systemIsDark)
        window.backgroundColor = palette.background
        // Native controls follow the palette, not the system, unless the palette follows the system.
        window.appearance = prefs.appearance == .system
            ? nil
            : NSAppearance(named: palette.background.isDark ? .darkAqua : .aqua)
        window.level = transcriptionPrefs.floatsOnTop ? .floating : .normal
    }

    private func observePreferences() {
        withObservationTracking {
            _ = prefs.palette(systemIsDark: true)
            _ = prefs.appearance
            _ = transcriptionPrefs.floatsOnTop
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyStyle()
                self?.observePreferences()
            }
        }
    }

    // MARK: - Saving

    func presentSavePanel(for transcript: Transcript) {
        guard let window else { return }
        let panel = NSSavePanel()
        let formats = ExportFormat.allCases
        let saved = ExportFormat(rawValue: UserDefaults.standard.string(forKey: ExportFormat.defaultsKey) ?? "") ?? .text
        panel.nameFieldStringValue = transcript.title.replacingOccurrences(of: ":", with: ".")
        panel.allowedContentTypes = [saved.type]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.label))
        popup.selectItem(at: formats.firstIndex(of: saved) ?? 0)
        let picker = FormatPicker(panel: panel, formats: formats)
        popup.target = picker
        popup.action = #selector(FormatPicker.changed(_:))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = row

        panel.beginSheetModal(for: window) { response in
            _ = picker
            guard response == .OK, let url = panel.url else { return }
            let format = formats[max(0, popup.indexOfSelectedItem)]
            UserDefaults.standard.set(format.rawValue, forKey: ExportFormat.defaultsKey)
            do {
                try format.render(transcript).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}

nonisolated enum ExportFormat: String, CaseIterable {
    case text, markdown, subtitles

    static let defaultsKey = "transcriptionExportFormat"

    var label: String {
        switch self {
        case .text: "Plain Text"
        case .markdown: "Markdown, with timestamps"
        case .subtitles: "Subtitles (SRT)"
        }
    }

    var type: UTType {
        switch self {
        case .text: .plainText
        case .markdown: UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md") ?? .plainText
        case .subtitles: UTType(filenameExtension: "srt") ?? .plainText
        }
    }

    @MainActor func render(_ transcript: Transcript) -> String {
        switch self {
        case .text: Transcript.join([transcript.plainText, transcript.tentative]) + "\n"
        case .markdown: transcript.markdown
        case .subtitles: transcript.subRip
        }
    }
}

/// Keeps the save panel's file type in step with the format popup.
private final class FormatPicker: NSObject {
    weak var panel: NSSavePanel?
    let formats: [ExportFormat]

    init(panel: NSSavePanel, formats: [ExportFormat]) {
        self.panel = panel
        self.formats = formats
    }

    @objc func changed(_ sender: NSPopUpButton) {
        panel?.allowedContentTypes = [formats[max(0, sender.indexOfSelectedItem)].type]
    }
}

/// Space starts and stops, Esc closes, ⌘C copies everything when nothing is selected, ⌘S saves.
final class TranscriptWindow: NSWindow {
    weak var transcription: TranscriptionController?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey(event) { return }
        super.sendEvent(event)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let transcription, attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let isEditing = (firstResponder as? NSTextView)?.isEditable == true
        switch (event.keyCode, modifiers) {
        case (49, []) where !isEditing:
            transcription.toggleRecording()
            return true
        case (53, []):
            performClose(nil)
            return true
        default:
            break
        }
        guard modifiers == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "s":
            transcription.save()
            return true
        case "c":
            if let text = firstResponder as? NSTextView, text.selectedRange().length > 0 { return false }
            transcription.copyAll()
            return true
        default:
            return false
        }
    }
}

fileprivate extension NSColor {
    /// Perceived brightness below the midpoint.
    var isDark: Bool {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
    }
}
