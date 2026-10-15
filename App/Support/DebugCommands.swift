#if DEBUG
import AppKit
import SwiftUI

/// `deadcenter://debug?cmd=…` — drives the reader in debug builds without synthesizing input.
enum DebugCommands {
    /// A clock that only moves forward, for `advance`.
    private static var clock: CFTimeInterval = 0

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
        case "libscan":
            LibraryState.shared.composing = false
            LibraryState.shared.scanning = true
        case "scanadd":
            if let path = value("path"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                if path.lowercased().hasSuffix(".pdf") { ScanDraft.shared.add(pdf: data) } else { ScanDraft.shared.add(images: [data]) }
            }
        case "scanread": ScanDraft.shared.read()
        case "mcpconnect":
            if let client = value("client").flatMap(AssistantSetup.Client.init(rawValue:)) {
                if value("off") == "1" { AssistantSetup.shared.disconnect(client) } else { AssistantSetup.shared.connect(client) }
            }
        case "renderpane":
            // Renders a settings pane off screen, for checking its layout without showing a window.
            if let out = value("out") {
                let theme = SettingsTheme(Preferences.shared.palette(systemIsDark: true))
                let pane = SettingsPane.all.first { $0.id == (value("id") ?? "general") } ?? SettingsPane.all[0]
                let renderer = ImageRenderer(content: pane.content()
                    .padding(28)
                    .frame(width: 620)
                    .background(theme.background)
                    .environment(\.settingsTheme, theme)
                    .environment(\.colorScheme, .dark))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                }
            }
        case "mcpstatus":
            AssistantSetup.shared.refresh()
            if let out = value("out") {
                let lines = AssistantSetup.Client.allCases.map { "\($0.rawValue): \(String(describing: AssistantSetup.shared.statuses[$0]))" }
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "dump":
            if let out = value("out"), let session {
                var lines: [String] = []
                var paragraph = -1
                var line = ""
                for item in session.stream.items {
                    switch item.kind {
                    case .word:
                        if item.paragraph != paragraph, !line.isEmpty { lines.append(line); line = "" }
                        paragraph = item.paragraph
                        line += (line.isEmpty || !item.spaceBefore ? "" : " ") + item.sourceText
                    case .image:
                        if !line.isEmpty { lines.append(line); line = "" }
                        lines.append("[IMAGE \(item.image?.pixelWidth ?? 0)x\(item.image?.pixelHeight ?? 0) caption: \(item.image?.caption ?? "-")]")
                    case .title:
                        if !line.isEmpty { lines.append(line); line = "" }
                        lines.append("# " + item.text)
                    }
                }
                if !line.isEmpty { lines.append(line) }
                try? (["TITLE: \(session.title)"] + lines).joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "libhome": LibraryState.shared.composing = false
        case "resume":
            let unfinished = LibraryStore.shared.all.filter { !$0.finished }
            let n = Int(value("n") ?? "0") ?? 0
            if unfinished.indices.contains(n) { coordinator.resume(unfinished[n]) }
        case "libdraft": LibraryState.shared.draft = value("q") ?? ""
        case "settings": SettingsWindowController.shared.show()
        case "closewin":
            NSApp.windows.first { $0.isVisible && $0.title == (value("title") ?? "") }?.performClose(nil)
        case "transcribe":
            if let path = value("path") { TranscriptionController.shared.transcribe(file: URL(fileURLWithPath: path)) }
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
        case "frame":
            if let out = value("out") {
                try? NSStringFromRect(coordinator.window.panel.frame).write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "winid":
            if let out = value("out") {
                try? "\(coordinator.window.panel.windowNumber)".write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "pagescroll":
            let pending = view.debugPageScroll(CGFloat(Double(value("y") ?? "0") ?? 0), location: value("loc").flatMap { Int($0) })
            if let out = value("out") { try? "\(pending)".write(toFile: out, atomically: true, encoding: .utf8) }
        case "advance":
            // Moves playback on by n beats without waiting for the clock (works while the window is hidden).
            if let session, session.state == .playing {
                for _ in 0..<(Int(value("n") ?? "1") ?? 1) {
                    clock = max(clock, CACurrentMediaTime()) + 120
                    session.tick(clock)
                }
            }
        case "pagestate":
            if let out = value("out") { try? view.debugPageState.write(toFile: out, atomically: true, encoding: .utf8) }
        case "matches":
            if let out = value("out"), let session {
                let stream = session.stream
                let lines = stream.matches(for: value("q") ?? "").map { "\($0) \(stream.items[$0].text)" }
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "state":
            if let out = value("out"), let session {
                let line = "\(session.state) index=\(session.index) count=\(session.stream.count) title=\(session.title) \(view.debugLinkState)"
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
