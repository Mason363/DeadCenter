import AppKit
import SwiftUI

struct AssistantsSettingsView: View {
    private var setup: AssistantSetup { AssistantSetup.shared }
    @State private var copied = false
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "Assistants",
                            footer: "Assistants can only hand Dead Center something to read: text they wrote, a web page, or a document. They can't see your library or what you've read.") {
                ForEach(Array(AssistantSetup.Client.allCases.enumerated()), id: \.element) { index, client in
                    if index > 0 { RowDivider() }
                    AssistantRow(client: client, status: setup.statuses[client] ?? .notConnected)
                }
            }

            SettingsSection(title: "Other Apps",
                            footer: "Any app that supports MCP, the Model Context Protocol, can run this command as a local server.") {
                SettingsRow(title: "Server command") {
                    HStack(spacing: 10) {
                        Text(setup.serverPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.ink.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                        DCButton(title: copied ? "Copied" : "Copy") { copy() }
                    }
                }
            }
        }
        .onAppear { setup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in setup.refresh() }
    }

    private func copy() {
        try? setup.installServer()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setup.serverPath, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

private struct AssistantRow: View {
    let client: AssistantSetup.Client
    let status: AssistantSetup.Status
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(client.name)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink.opacity(0.88))
                StatusLabel(text: statusText, color: dotColor)
                    .lineLimit(2)
            }
            Spacer()
            switch status {
            case .notConnected:
                DCButton(title: "Connect") { AssistantSetup.shared.connect(client) }
            case .connected:
                DCButton(title: "Disconnect") { AssistantSetup.shared.disconnect(client) }
            case .restartNeeded, .failed:
                DCButton(title: "OK") { AssistantSetup.shared.dismiss(client) }
            case .working:
                ProgressView().controlSize(.small)
            case .missing:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(status == .missing ? 0.5 : 1)
    }

    @ViewBuilder private var icon: some View {
        if client == .claudeDesktop, let app = AssistantSetup.claudeDesktopApp {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable()
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 15))
                .foregroundStyle(theme.ink.opacity(0.7))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.ink.opacity(0.08)))
        }
    }

    private var statusText: String {
        switch status {
        case .missing: "Not installed"
        case .notConnected: "Not connected"
        case .connected: "Connected"
        case .working: "Connecting…"
        case .restartNeeded: "Connected. Quit and reopen Claude to finish."
        case .failed(let message): message
        }
    }

    private var dotColor: Color {
        switch status {
        case .connected, .restartNeeded: .green
        case .failed: .red
        case .working: .orange
        case .missing, .notConnected: theme.ink.opacity(0.3)
        }
    }
}
