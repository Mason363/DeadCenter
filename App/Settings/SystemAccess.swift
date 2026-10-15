import AppKit
import ApplicationServices
import Observation
import ServiceManagement

/// Live Accessibility trust, shared by Settings and onboarding.
@Observable
final class AccessibilityAccess {
    static let shared = AccessibilityAccess()

    private(set) var isTrusted = AXIsProcessTrusted()

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
    }

    /// Adds Dead Center to the Accessibility list (with the system prompt) and opens that pane.
    func request() {
        // The literal value of kAXTrustedCheckOptionPrompt; the imported global isn't concurrency-safe.
        isTrusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !isTrusted {
            NSWorkspace.shared.open(Self.settingsURL)
        }
    }
}

/// Launch at login through SMAppService, reflecting what the system actually has registered.
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    private(set) var status = SMAppService.mainApp.status
    private(set) var errorMessage: String?

    /// On as far as the user is concerned: registered, or registered and waiting for approval.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = on
                ? "Couldn't add Dead Center to your login items. \(error.localizedDescription)"
                : "Couldn't remove Dead Center from your login items. \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
