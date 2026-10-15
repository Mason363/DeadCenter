import AppKit
import SwiftUI

/// The Settings window (⌘,), drawn in the reader's own palette rather than the system's grouped forms.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private static let autosaveName = "DeadCenterSettingsWindow"

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 700, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone]
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.setContentSize(NSSize(width: 760, height: 600))
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        WindowTheming.track(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        DockPresence.shared.enter(self)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.shared.leave(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        AccessibilityAccess.shared.refresh()
        LaunchAtLogin.shared.refresh()
    }
}

/// The panes, in sidebar order. Optional features (transcription) add theirs to `extras`.
struct SettingsPane: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let content: @MainActor () -> AnyView

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static var extras: [SettingsPane] = []

    static var all: [SettingsPane] {
        [
            SettingsPane(id: "general", title: "General", symbol: "gearshape") { AnyView(GeneralSettingsView()) },
            SettingsPane(id: "reading", title: "Reading", symbol: "text.alignleft") { AnyView(ReadingSettingsView()) },
            SettingsPane(id: "appearance", title: "Appearance", symbol: "paintpalette") { AnyView(AppearanceSettingsView()) },
            SettingsPane(id: "browsers", title: "Browsers", symbol: "globe") { AnyView(BrowsersSettingsView()) },
            SettingsPane(id: "assistants", title: "Assistants", symbol: "sparkles") { AnyView(AssistantsSettingsView()) },
        ] + extras
    }
}

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("SettingsSelectedTabID") private var selectedID = "general"

    private var theme: SettingsTheme {
        SettingsTheme(Preferences.shared.palette(systemIsDark: colorScheme == .dark))
    }

    private var selected: SettingsPane {
        SettingsPane.all.first { $0.id == selectedID } ?? SettingsPane.all[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(theme.ink.opacity(0.06)).frame(width: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(selected.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.ink.opacity(0.92))
                    selected.content()
                }
                .padding(.horizontal, 30)
                .padding(.top, 40)
                .padding(.bottom, 30)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(selected.id)
                .transition(.opacity)
            }
            .scrollIndicators(.automatic)
        }
        .background(theme.background.ignoresSafeArea())
        .environment(\.settingsTheme, theme)
        .tint(theme.accent)
        .animation(.easeOut(duration: 0.18), value: selectedID)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.all) { pane in
                SidebarItem(pane: pane, selected: pane.id == selected.id, theme: theme) {
                    selectedID = pane.id
                }
            }
            Spacer()
        }
        .padding(.top, 52)
        .padding(.horizontal, 10)
        .frame(width: 180)
        .background(theme.ink.opacity(0.02).ignoresSafeArea())
    }
}

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let theme: SettingsTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.ink.opacity(selected ? 0.95 : (hovering ? 0.75 : 0.55)))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.ink.opacity(selected ? 0.08 : (hovering ? 0.04 : 0))))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
