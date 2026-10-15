import AppKit

/// The floating reader window: a titled, non-activating panel so it can take keys without
/// stealing focus from the app you were reading in.
final class ReaderPanel: NSPanel {
    var allowsAnyFrame = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 860, height: 300),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovableByWindowBackground = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        minSize = NSSize(width: 340, height: 120)
        title = "Dead Center"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsAnyFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// Shows, sizes, and animates the reader panel, including the custom full-screen mode.
final class ReaderWindowController: NSObject, NSWindowDelegate, ReaderViewHost {
    let panel = ReaderPanel()
    let readerView = ReaderView()
    var onClose: (() -> Void)?

    private let container = NSView()
    private var materialView: NSView?
    private(set) var isFullScreen = false
    private var frameBeforeFullScreen: NSRect?
    private var frameBeforeImage: NSRect?
    private var isAnimating = false
    private var closeGeneration = 0
    private let prefs = Preferences.shared
    private static let frameKey = "readerFrame"
    private static let pageFrameKey = "readerPageFrame"
    /// The reading mode the window's current frame belongs to; each mode remembers its own size.
    private var frameMode = Preferences.shared.readingMode
    private var currentFrameKey: String { frameMode == .page ? Self.pageFrameKey : Self.frameKey }

    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        container.wantsLayer = true
        readerView.autoresizingMask = [.width, .height]
        readerView.host = self
        container.addSubview(readerView)
        panel.contentView = container
        panel.delegate = self
        applyMaterial()
        observeMaterial()
    }

    // MARK: - Show / hide

    func show(_ session: ReaderSession) {
        readerView.session = session
        // Cancels a close that's still animating out.
        closeGeneration += 1
        if panel.isVisible {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(readerView)
            return
        }
        let target = initialFrame()
        panel.setFrame(target, display: false)
        readerView.frame = container.bounds
        panel.makeFirstResponder(readerView)

        // Fade in with a small rise. Only the position moves, so nothing re-lays out mid-animation.
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = reduce ? target : target.offsetBy(dx: 0, dy: -10)
        panel.setFrame(start, display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0.15 : 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrameOrigin(target.origin)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard panel.isVisible else { return }
        if isFullScreen { leaveFullScreen(animated: false) }
        restoreFromImage(animated: false)
        let frame = panel.frame
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        closeGeneration += 1
        let generation = closeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0.12 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().alphaValue = 0
            if !reduce { panel.animator().setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - 6)) }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Something was opened again while this was fading out: leave it on screen.
                guard let self, self.closeGeneration == generation else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.panel.setFrame(frame, display: false)
            }
        })
        onClose?()
    }

    // MARK: - Frames

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func initialFrame() -> NSRect {
        let screen = activeScreen()
        let visible = screen.visibleFrame
        frameMode = prefs.readingMode
        if let saved = UserDefaults.standard.string(forKey: currentFrameKey).map(NSRectFromString),
           saved.width >= panel.minSize.width, visible.contains(saved) {
            return saved
        }
        if frameMode == .page { return centered(pageSize(in: visible), in: visible) }
        let size = savedSize() ?? prefs.windowSize.size
        return centered(size, in: visible)
    }

    /// A page-shaped window: a comfortable measure and most of the screen's height.
    private func pageSize(in visible: NSRect) -> NSSize {
        NSSize(width: min(860, visible.width - 80), height: min(max(visible.height * 0.7, 480), 820))
    }

    private func savedSize() -> NSSize? {
        UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString).map(\.size)
            .flatMap { $0.width >= panel.minSize.width ? $0 : nil }
    }

    private func centered(_ size: NSSize, in visible: NSRect) -> NSRect {
        let w = min(size.width, visible.width - 40)
        let h = min(size.height, visible.height - 40)
        // Slightly above center, where the eye rests.
        return NSRect(x: (visible.midX - w / 2).rounded(), y: (visible.midY - h / 2 + visible.height * 0.06).rounded(),
                      width: w, height: h)
    }

    private func saveFrame() {
        guard !isFullScreen, frameBeforeImage == nil, !isAnimating, panel.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: currentFrameKey)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func animate(to frame: NSRect, duration: TimeInterval = 0.32, completion: (@MainActor () -> Void)? = nil) {
        // Frame animations only advance on screen; a hidden window just takes its new frame.
        guard panel.occlusionState.contains(.visible) else {
            panel.setFrame(frame, display: false)
            completion?()
            return
        }
        isAnimating = true
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0 : duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.2, 1)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isAnimating = false
                completion?()
            }
        })
    }

    // MARK: - ReaderViewHost

    func readerViewRequestsClose(_ view: ReaderView) {
        close()
    }

    func readerView(_ view: ReaderView, requestsSize preset: WindowSizePreset) {
        prefs.windowSize = preset
        if isFullScreen { leaveFullScreen(animated: true) }
        frameBeforeImage = nil
        let visible = panel.screen?.visibleFrame ?? activeScreen().visibleFrame
        var target = centered(preset.size, in: visible)
        // Keep the window's center where it is when there's room.
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        target.origin = NSPoint(x: (center.x - target.width / 2).rounded(), y: (center.y - target.height / 2).rounded())
        target = target.constrained(to: visible)
        animate(to: target) { [weak self] in self?.saveFrame() }
        view.flash(preset.label)
    }

    func readerViewRequestsFullScreen(_ view: ReaderView) {
        if isFullScreen { leaveFullScreen(animated: true) } else { enterFullScreen() }
    }

    func readerView(_ view: ReaderView, imageBeatActive active: Bool) {
        // The page shows its pictures inline; only the focus view grows for them.
        guard frameMode == .focus || !active else { return }
        if active { expandForImage() } else { restoreFromImage(animated: true) }
    }

    func readerView(_ view: ReaderView, didSwitchTo mode: ReadingMode) {
        guard mode != frameMode else { return }
        restoreFromImage(animated: false)
        saveFrame()
        frameMode = mode
        guard panel.isVisible, !isFullScreen else { return }
        let visible = panel.screen?.visibleFrame ?? activeScreen().visibleFrame
        let saved = UserDefaults.standard.string(forKey: currentFrameKey).map(NSRectFromString)
            .flatMap { $0.width >= panel.minSize.width ? $0.size : nil }
        let size = saved ?? (mode == .page ? pageSize(in: visible) : (savedSize() ?? prefs.windowSize.size))
        // Grow or shrink around the window's top center, so the text stays where the eye is.
        let frame = panel.frame
        var target = NSRect(x: (frame.midX - size.width / 2).rounded(), y: (frame.maxY - size.height).rounded(),
                            width: size.width, height: size.height)
        target = target.constrained(to: visible)
        animate(to: target, duration: 0.38) { [weak self] in self?.saveFrame() }
    }

    // MARK: - Full screen

    private func enterFullScreen() {
        guard !isFullScreen else { return }
        restoreFromImage(animated: false)
        let screen = panel.screen ?? activeScreen()
        frameBeforeFullScreen = panel.frame
        isFullScreen = true
        isAnimating = true
        NSApp.activate()
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        panel.allowsAnyFrame = true
        panel.level = .statusBar
        animate(to: screen.frame, duration: 0.42) { [weak self] in
            guard let self, self.isFullScreen else { return }
            // Square corners once we fill the display.
            self.panel.styleMask.remove(.titled)
            self.panel.setFrame(screen.frame, display: true)
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.readerView)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func leaveFullScreen(animated: Bool) {
        guard isFullScreen else { return }
        isFullScreen = false
        isAnimating = true
        if !panel.styleMask.contains(.titled) {
            let frame = panel.frame
            panel.styleMask.insert(.titled)
            panel.setFrame(frame, display: true)
            panel.makeFirstResponder(readerView)
        }
        NSApp.presentationOptions = []
        panel.level = .floating
        let target = frameBeforeFullScreen ?? centered(prefs.windowSize.size, in: activeScreen().visibleFrame)
        frameBeforeFullScreen = nil
        if animated {
            animate(to: target, duration: 0.36) { [weak self] in self?.panel.allowsAnyFrame = false }
        } else {
            panel.setFrame(target, display: true)
            panel.allowsAnyFrame = false
            isAnimating = false
        }
    }

    // MARK: - Image beats

    /// Small windows grow for an image beat, then settle back.
    private func expandForImage() {
        guard !isFullScreen, frameBeforeImage == nil, panel.isVisible else { return }
        let frame = panel.frame
        guard frame.height < 400 else { return }
        let visible = panel.screen?.visibleFrame ?? activeScreen().visibleFrame
        let height = min(max(420, frame.width * 0.62), visible.height - 40)
        let width = max(frame.width, 640)
        var target = NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        target = target.integral.constrained(to: visible)
        frameBeforeImage = frame
        animate(to: target, duration: 0.38)
    }

    private func restoreFromImage(animated: Bool) {
        guard let frame = frameBeforeImage else { return }
        frameBeforeImage = nil
        if animated {
            animate(to: frame, duration: 0.32)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Material

    private func observeMaterial() {
        withObservationTracking {
            _ = prefs.material
            _ = prefs.appearance
            _ = prefs.customBackgroundHex
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.applyMaterial()
                self?.observeMaterial()
            }
        }
    }

    private func applyMaterial() {
        materialView?.removeFromSuperview()
        materialView = nil
        guard prefs.material == .glass else {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            panel.isOpaque = true
            panel.backgroundColor = prefs.palette(systemIsDark: dark).background
            return
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let view: NSView
        if #available(macOS 26.0, *) {
            view = NSGlassEffectView()
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            view = effect
        }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view, positioned: .below, relativeTo: readerView)
        materialView = view
    }
}

extension NSRect {
    /// Moves the rect inside `bounds` (shrinking only if it can't fit).
    func constrained(to bounds: NSRect) -> NSRect {
        var r = self
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }
}
