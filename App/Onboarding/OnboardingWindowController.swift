import AppKit
import SwiftUI

/// First-run welcome: teaches RSVP by doing it, asks for Accessibility, shows the hotkey.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    static let size = NSSize(width: 640, height: 440)

    private init() {
        let window = OnboardingWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                      styleMask: [.titled, .closable, .fullSizeContentView],
                                      backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone]
        window.title = "Welcome to Dead Center"
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        if !window.isVisible {
            // A fresh view each time, so it always starts at the first step.
            let view = OnboardingView(
                onFinish: { [weak self] in self?.finish() },
                onAccessGranted: { [weak self] in self?.bringToFront() })
            let host = NSHostingController(rootView: view)
            // Fixed-size window: don't let SwiftUI's safe-area-inclusive sizing grow it past 640×440.
            host.sizingOptions = []
            window.contentViewController = host
            window.setContentSize(Self.size)
            window.center()
        }
        DockPresence.shared.enter(self)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.shared.leave(self)
    }

    private func finish() {
        Preferences.shared.hasCompletedOnboarding = true
        close()
        LibraryWindowController.shared.show()
    }

    /// Called when Accessibility is granted while System Settings is in front.
    private func bringToFront() {
        guard let window, window.isVisible else { return }
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKey()
    }
}

/// Chromeless, but still key-capable and closable with ⌘W.
private final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
