import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowsersSettingsView: View {
    @State private var statuses: [BrowserKind: BrowserExtensionStatus] = [:]

    var body: some View {
        SettingsSection(title: "Extensions",
                        footer: "The shortcut and right-click ▸ Services ▸ Read in Dead Center work in every app, no extension needed.") {
            ForEach(Array(BrowserKind.allCases.enumerated()), id: \.element) { index, browser in
                if index > 0 { RowDivider() }
                BrowserRow(browser: browser, status: statuses[browser] ?? .notConnected)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private func refresh() {
        for browser in BrowserKind.allCases {
            statuses[browser] = BrowserIntegration.shared.status(for: browser)
        }
    }
}

private struct BrowserRow: View {
    let browser: BrowserKind
    let status: BrowserExtensionStatus
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(browser.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink.opacity(0.88))
                StatusLabel(text: statusText, color: dotColor)
            }
            Spacer()
            if status == .notConnected {
                DCButton(title: "Set Up…") { BrowserIntegration.shared.openInstallInstructions(for: browser) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(status == .browserMissing ? 0.5 : 1)
    }

    private var statusText: String {
        switch status {
        case .connected: "Connected"
        case .notConnected: "Not set up"
        case .browserMissing: "Not installed"
        }
    }

    private var dotColor: Color {
        switch status {
        case .connected: .green
        case .notConnected: theme.ink.opacity(0.3)
        case .browserMissing: theme.ink.opacity(0.15)
        }
    }

    private var bundleIdentifier: String {
        switch browser {
        case .chrome: "com.google.Chrome"
        case .zen: "app.zen-browser.zen"
        case .safari: "com.apple.Safari"
        }
    }

    private var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
