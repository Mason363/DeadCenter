import Combine
import KeyboardShortcuts
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable private var prefs = Preferences.shared
    @Bindable private var updater = Updater.shared
    private var accessibility = AccessibilityAccess.shared
    private var launchAtLogin = LaunchAtLogin.shared
    @State private var confirmingClearHistory = false
    @Environment(\.settingsTheme) private var theme

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "Shortcuts") {
                SettingsRow(title: "Read selection") {
                    KeyboardShortcuts.Recorder(for: .read)
                }
                RowDivider()
                SettingsRow(title: "Read clipboard") {
                    KeyboardShortcuts.Recorder(for: .readClipboard)
                }
            }

            SettingsSection(title: "Reading") {
                SettingsRow(title: "Start reading automatically") {
                    DCToggle(isOn: $prefs.autoStart)
                }
                RowDivider()
                SettingsRow(title: "Remember reading history") {
                    DCToggle(isOn: $prefs.rememberHistory)
                }
                RowDivider()
                SettingsRow(title: "Clear reading history") {
                    DCButton(title: "Clear…", destructive: true) { confirmingClearHistory = true }
                }
            }

            SettingsSection(title: "Page Scans",
                            footer: "Everything happens on your Mac with Apple's built-in text recognition. Nothing to download.") {
                SettingsRow(title: "Scan pages with your iPhone",
                            detail: "Photograph textbook pages and papers. Pages are straightened, columns read in order, and figures kept as pictures.") {
                    DCToggle(isOn: $prefs.pageScanning)
                }
            }

            SettingsSection(title: "System") {
                SettingsRow(title: "Launch at login", detail: launchDetail) {
                    HStack(spacing: 10) {
                        if launchAtLogin.needsApproval {
                            DCButton(title: "Login Items…") { launchAtLogin.openLoginItemsSettings() }
                        }
                        DCToggle(isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.set($0) }))
                    }
                }
                RowDivider()
                SettingsRow(title: "Accessibility",
                            detail: accessibility.isTrusted ? nil : "Lets the shortcut read what you select in other apps.") {
                    if accessibility.isTrusted {
                        StatusLabel(text: "Granted", color: .green)
                    } else {
                        DCButton(title: "Grant Access…") { accessibility.request() }
                    }
                }
            }

            SettingsSection(title: "Updates") {
                SettingsRow(title: "Check automatically") {
                    DCToggle(isOn: $updater.automaticallyChecksForUpdates)
                }
                RowDivider()
                SettingsRow(title: Self.versionString) {
                    DCButton(title: "Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .confirmationDialog("Clear reading history?", isPresented: $confirmingClearHistory) {
            Button("Clear History", role: .destructive) {
                NotificationCenter.default.post(name: Notification.Name("DeadCenterClearHistory"), object: nil)
            }
        } message: {
            Text("Dead Center will forget your place in everything you've read.")
        }
        .onReceive(poll) { _ in
            accessibility.refresh()
            launchAtLogin.refresh()
        }
    }

    private var launchDetail: String? {
        if let message = launchAtLogin.errorMessage { return message }
        if launchAtLogin.needsApproval { return "Allow Dead Center in System Settings to finish." }
        return nil
    }

    private static let versionString: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        return "Dead Center \(version) (\(build))"
    }()
}
