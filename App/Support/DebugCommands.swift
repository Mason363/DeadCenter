#if DEBUG
import AppKit

/// `deadcenter://debug?cmd=…` — drives the reader in debug builds without synthesizing input.
enum DebugCommands {
    static func run(_ items: [URLQueryItem]) {
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let coordinator = ReadingCoordinator.shared
        let session = coordinator.session
        let view = coordinator.window.readerView
        switch value("cmd") {
        case "play": session?.play()
        case "pause": session?.pause()
        case "step": session?.step(Int(value("n") ?? "1") ?? 1)
        case "seek": session?.seek(to: Int(value("n") ?? "0") ?? 0)
        case "full": coordinator.window.readerViewRequestsFullScreen(view)
        case "size":
            let preset = WindowSizePreset(rawValue: Int(value("n") ?? "2") ?? 2) ?? .regular
            coordinator.window.readerView(view, requestsSize: preset)
        case "scrub": view.debugScrub(by: CGFloat(Double(value("n") ?? "0") ?? 0))
        case "help": view.debugToggleHelp()
        case "page": view.togglePage()
        case "find":
            view.showFind()
            if let q = value("q") { view.debugFind(q) }
        case "compose": coordinator.compose()
        case "closebtn": view.debugShowClose()
        case "library": LibraryWindowController.shared.show()
        case "libcompose": LibraryWindowController.shared.compose()
        case "libhome": LibraryState.shared.composing = false
        case "libdraft": LibraryState.shared.draft = value("q") ?? ""
        case "settings": SettingsWindowController.shared.show()
        case "winof":
            if let out = value("out") {
                let number = NSApp.windows.first { $0.isVisible && $0.title == (value("title") ?? "") }?.windowNumber ?? 0
                try? "\(number)".write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "follow": TranscriptionController.shared.followsInReader = value("on") != "0"
        case "transcript":
            if let out = value("out") {
                try? TranscriptionController.shared.exportText.write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "pane": UserDefaults.standard.set(value("id") ?? "general", forKey: "SettingsSelectedTabID")
        case "setwin":
            if let out = value("out") {
                let number = NSApp.windows.first { $0.isVisible && $0.title != "Dead Center" && $0.contentViewController != nil }?.windowNumber ?? 0
                try? "\(number)".write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "libwin":
            if let out = value("out") {
                try? "\(LibraryWindowController.shared.window?.windowNumber ?? 0)".write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "type": view.debugType(value("q") ?? "")
        case "timeline": view.debugTimeline(at: CGFloat(Double(value("x") ?? "0.5") ?? 0.5))
        case "close": coordinator.window.close()
        case "wpm": Preferences.shared.wpm = Int(value("n") ?? "350") ?? 350
        case "winid":
            if let out = value("out") {
                try? "\(coordinator.window.panel.windowNumber)".write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "state":
            if let out = value("out"), let session {
                let line = "\(session.state) index=\(session.index) count=\(session.stream.count) title=\(session.title)"
                try? line.write(toFile: out, atomically: true, encoding: .utf8)
            }
        default: break
        }
    }
}

extension ReaderView {
    func debugScrub(by delta: CGFloat) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: 0, wheel2: Int32(delta), wheel3: 0),
              let ns = NSEvent(cgEvent: event) else { return }
        scrollWheel(with: ns)
    }

    func debugToggleHelp() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                                     windowNumber: window?.windowNumber ?? 0, context: nil, characters: "?",
                                     charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44)
        if let event { keyDown(with: event) }
    }
}
#endif
