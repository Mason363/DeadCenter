import AppKit
import SwiftUI
import QuartzCore
import DCEngine

/// Window-level requests the reader can't fulfil itself.
protocol ReaderViewHost: AnyObject {
    var isFullScreen: Bool { get }
    func readerViewRequestsClose(_ view: ReaderView)
    func readerViewRequestsFullScreen(_ view: ReaderView)
    func readerView(_ view: ReaderView, requestsSize preset: WindowSizePreset)
    func readerView(_ view: ReaderView, imageBeatActive active: Bool)
}

/// The reading surface. Renders with Core Text into layers, drives playback from the display link,
/// and handles every keyboard, mouse and trackpad interaction.
final class ReaderView: NSView, ReaderSessionDelegate {
    weak var host: ReaderViewHost?
    /// A reduced surface for Settings and onboarding: no info line, HUD, or shortcuts overlay.
    var isPreview = false

    var session: ReaderSession? {
        didSet {
            if oldValue !== session { oldValue?.delegate = nil }
            session?.delegate = self
            sessionReplaced()
        }
    }

    private let prefs = Preferences.shared
    private let wordLayer = WordLayer()
    private let ribbon = RibbonLayer()
    private let revealMask = CAGradientLayer()
    private let titleLayer = StillTextLayer()
    private let messageLayer = StillTextLayer()
    private let imageLayer = StillLayer()
    private let countdownLayer = StillLayer()
    private let dotLayer = StillLayer()
    private let infoLayer = StillTextLayer()
    private let hudLayer = StillTextLayer()
    private let progressLayer = StillLayer()
    private let guideTop = StillLayer()
    private let guideBottom = StillLayer()
    private var helpView: NSHostingView<ShortcutsOverlay>?
    private let hoverLabel = StillTextLayer()
    private var timelineActive = false
    private var timelineDragging = false
    private var pageView: PageView?
    private var pageGeneration = -1
    private var findBar: FindBar?
    private var bar: NSHostingView<ReaderChrome>?
    private let barModel = ReaderChromeModel()
    private(set) var controlsVisible = false
    private var controlsHideWork: DispatchWorkItem?
    private var lastTimeTextUpdate: CFTimeInterval = 0
    private var closeButton: NSHostingView<CloseButton>?
    #if DEBUG
    private var pinCloseForDebug = false
    #endif
    static let barHeight: CGFloat = 46
    /// Distance from the window's top and left edges to the center of the ×.
    static let closeInset: CGFloat = 19
    private var findMatches: [Int] = []
    private var findCurrent: Int?

    private var link: CADisplayLink?
    private(set) var palette: ReaderPalette = .dark
    private var style = WordStyle(font: .systemFont(ofSize: 60), pivotFont: .systemFont(ofSize: 60),
                                  text: .white, pivot: .systemRed)
    private var fontSize: CGFloat = 60
    private var baseline: CGFloat = 0
    private var lineLayerBaseline: CGFloat = 0

    private var ribbonVisible = false
    private var ribbonGeneration = 0
    private var scrubbing = false
    private var shiftTween: Tween?
    private var snapWork: DispatchWorkItem?

    private let images = ImageLoader()
    private var shownImageIndex: Int?
    private var shownImage: CGImage?
    private var hudWork: DispatchWorkItem?
    private var remaining: (index: Int, seconds: Double)?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setUpLayers()
        observePreferences()
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Dead Center reader")
        registerForDraggedTypes([.fileURL, .URL, .string, .html, .rtf, .png, .tiff])
    }

    // MARK: - Drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !isPreview, sender.draggingSource as? NSView == nil else { return [] }
        layer?.borderColor = palette.pivot.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 2
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        layer?.borderWidth = 0
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        switch PasteboardReader.content(of: sender.draggingPasteboard, origin: .text) {
        case .files(let urls): ReadingCoordinator.shared.open(urls)
        case .request(let request): ReadingCoordinator.shared.read(request)
        case nil: return false
        }
        return true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { !isPreview }
    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Setup

    private func setUpLayers() {
        guard let root = layer else { return }
        root.masksToBounds = true

        revealMask.startPoint = CGPoint(x: 0, y: 0.5)
        revealMask.endPoint = CGPoint(x: 1, y: 0.5)
        revealMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        revealMask.locations = [0, 0.12, 0.88, 1]
        ribbon.mask = revealMask
        ribbon.isHidden = true

        for text in [titleLayer, messageLayer, infoLayer, hudLayer] {
            text.alignmentMode = .center
            text.truncationMode = .middle
        }
        titleLayer.isWrapped = true
        messageLayer.isWrapped = true
        titleLayer.isHidden = true
        messageLayer.isHidden = true
        hudLayer.opacity = 0
        infoLayer.opacity = 0

        imageLayer.contentsGravity = .resize
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = 8
        imageLayer.cornerCurve = .continuous
        imageLayer.isHidden = true
        countdownLayer.cornerRadius = 1
        countdownLayer.isHidden = true

        dotLayer.isHidden = true
        progressLayer.isHidden = true
        hoverLabel.isHidden = true
        hoverLabel.alignmentMode = .center
        hoverLabel.truncationMode = .end
        guideTop.isHidden = true
        guideBottom.isHidden = true

        for l in [ribbon, wordLayer, titleLayer, messageLayer, imageLayer, countdownLayer, dotLayer,
                  guideTop, guideBottom, progressLayer, infoLayer, hoverLabel, hudLayer] as [CALayer] {
            root.addSublayer(l)
        }
    }

    private func observePreferences() {
        withObservationTracking {
            _ = prefs.wpm; _ = prefs.pacing; _ = prefs.pivotMode; _ = prefs.appearance
            _ = prefs.customBackgroundHex; _ = prefs.customTextHex; _ = prefs.customPivotHex
            _ = prefs.fontFamily; _ = prefs.fontWeight; _ = prefs.textScale; _ = prefs.boldPivot
            _ = prefs.showGuides; _ = prefs.progressVisibility; _ = prefs.material
            _ = prefs.showImages; _ = prefs.imageDuration
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.preferencesChanged()
                self?.observePreferences()
            }
        }
    }

    private func preferencesChanged() {
        session?.timingChanged()
        remaining = nil
        refreshStyle()
        renderAll()
    }

    // MARK: - View lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(frame(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        updateContentsScale()
        refreshStyle()
        installControlsIfNeeded()
        renderAll()
        updateDisplayLink()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle()
        renderAll()
    }

    override func layout() {
        super.layout()
        refreshStyle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        renderItem()
        if ribbonVisible {
            buildRibbon(anchor: session?.index ?? 0)
            ribbon.shift = 0
        }
        renderChrome()
        CATransaction.commit()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
        for l in [layer, wordLayer, ribbon, titleLayer, messageLayer, imageLayer, infoLayer, hudLayer, hoverLabel] as [CALayer?] {
            l?.contentsScale = scale
        }
        wordLayer.setNeedsDisplay()
        ribbon.setNeedsDisplay()
    }

    // MARK: - Style & geometry

    private var systemIsDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func refreshStyle() {
        palette = prefs.palette(systemIsDark: systemIsDark)
        let byHeight = bounds.height * 0.30
        let byWidth = bounds.width * 0.09
        fontSize = max(13, min(byHeight, byWidth, 240)) * CGFloat(prefs.textScale)
        let font = prefs.font(size: fontSize)
        let pivotFont = prefs.boldPivot ? prefs.font(size: fontSize, bold: true) : font
        style = WordStyle(font: font, pivotFont: pivotFont, text: palette.text, pivot: palette.pivot)
        baseline = (bounds.midY - font.capHeight / 2).rounded()
        ribbon.wordStyle = style
        applyPalette()
    }

    private func applyPalette() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = prefs.material == .glass && !isPreview
            ? palette.background.withAlphaComponent(0.18).cgColor
            : palette.background.cgColor
        let secondary = palette.text.withAlphaComponent(0.45).cgColor
        titleLayer.foregroundColor = palette.text.withAlphaComponent(0.78).cgColor
        messageLayer.foregroundColor = palette.text.withAlphaComponent(0.7).cgColor
        infoLayer.foregroundColor = secondary
        hudLayer.foregroundColor = palette.text.withAlphaComponent(0.8).cgColor
        progressLayer.backgroundColor = palette.text.withAlphaComponent(0.28).cgColor
        guideTop.backgroundColor = palette.text.withAlphaComponent(0.22).cgColor
        guideBottom.backgroundColor = guideTop.backgroundColor
        dotLayer.backgroundColor = palette.pivot.cgColor
        countdownLayer.backgroundColor = palette.pivot.withAlphaComponent(0.85).cgColor
        hoverLabel.foregroundColor = palette.text.withAlphaComponent(0.75).cgColor
        CATransaction.commit()
        findBar?.apply(palette)
        barModel.palette = palette
        closeButton?.rootView = makeCloseButton()
        if let page = pageView {
            page.layer?.backgroundColor = palette.background.cgColor
            page.apply(palette: palette, font: pageFont())
        }
    }

    private func layoutLayers() {
        let lineHeight = (fontSize * 1.9).rounded()
        let lineBottom = (baseline - fontSize * 0.6).rounded()
        let lineRect = CGRect(x: 0, y: lineBottom, width: bounds.width, height: lineHeight)
        lineLayerBaseline = baseline - lineBottom
        wordLayer.frame = lineRect
        wordLayer.pivotX = bounds.midX
        wordLayer.baseline = lineLayerBaseline
        ribbon.frame = lineRect
        ribbon.baseline = lineLayerBaseline
        revealMask.frame = ribbon.bounds

        let small = NSFont.systemFont(ofSize: 12, weight: .medium)
        infoLayer.font = small
        infoLayer.fontSize = 12
        infoLayer.frame = CGRect(x: 40, y: bar == nil ? 14 : Self.barHeight + 4, width: max(bounds.width - 80, 0), height: 16)
        hudLayer.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        hudLayer.fontSize = 13
        hudLayer.frame = CGRect(x: 40, y: bounds.height - 34, width: max(bounds.width - 80, 0), height: 18)

        let titleSize = max(15, fontSize * 0.42)
        titleLayer.font = prefs.font(size: titleSize)
        titleLayer.fontSize = titleSize
        let titleHeight = titleSize * 2.6
        titleLayer.frame = CGRect(x: 32, y: bounds.midY - titleHeight / 2 - titleSize * 0.15,
                                  width: max(bounds.width - 64, 0), height: titleHeight)
        messageLayer.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        messageLayer.fontSize = 15
        messageLayer.frame = CGRect(x: 32, y: bounds.midY - 24, width: max(bounds.width - 64, 0), height: 44)

        let dot = max(8, fontSize * 0.16).rounded()
        dotLayer.frame = CGRect(x: bounds.midX - dot / 2, y: baseline + style.font.capHeight / 2 - dot / 2,
                                width: dot, height: dot)
        dotLayer.cornerRadius = dot / 2

        let tick = (fontSize * 0.16).rounded()
        guideTop.frame = CGRect(x: bounds.midX - 1, y: baseline + style.font.capHeight + fontSize * 0.26,
                                width: 2, height: tick)
        guideBottom.frame = CGRect(x: bounds.midX - 1, y: baseline - fontSize * 0.32 - tick, width: 2, height: tick)

        if let image = shownImage { imageLayer.frame = imageRect(for: image) }
        countdownLayer.frame = CGRect(x: bounds.midX - 60, y: 12, width: 120, height: 2)
        hoverLabel.font = small
        hoverLabel.fontSize = 12
    }

    // MARK: - Session

    private func sessionReplaced() {
        barModel.session = session
        updateTimeText(force: true)
        images.reset()
        shownImageIndex = nil
        shownImage = nil
        remaining = nil
        shiftTween = nil
        scrubbing = false
        ribbonVisible = false
        ribbon.isHidden = true
        ribbon.entries = []
        hideHelp()
        renderAll()
        if session?.state == .paused { showRibbon(animated: false) }
        updateDisplayLink()
    }

    func session(_ session: ReaderSession, didChange change: ReaderSession.Change) {
        switch change {
        case .item:
            remaining = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderItem()
            renderChrome()
            CATransaction.commit()
            if ribbonVisible, !scrubbing { alignRibbon(animated: !timelineDragging) }
            images.preload(session.stream, from: session.index)
            pageView?.highlight(session.index, scroll: false)
            updateTimeText(force: false)
        case .state:
            stateChanged()
        case .content:
            renderAll()
            images.preload(session.stream, from: session.index)
            syncPage()
            updateTimeText(force: true)
        }
    }

    private func stateChanged() {
        guard let session else { return }
        remaining = nil
        switch session.state {
        case .playing:
            hideRibbon(animated: true)
            hideHelp()
            if !isPreview, let window, window.isKeyWindow,
               bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        case .paused, .finished:
            if session.currentItem?.kind == .word { showRibbon(animated: true) }
        case .loading, .failed:
            hideRibbon(animated: false)
        }
        updateTimeText(force: true)
        setControls(visible: session.state != .playing)
        renderAll()
        updateDisplayLink()
    }

    // MARK: - Rendering

    private func renderAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyPalette()
        renderItem()
        renderChrome()
        CATransaction.commit()
    }

    /// The word as the focus view shows it, plus the marks of the aside or quote it sits in.
    private func typeset(_ item: ReadingItem) -> (word: TypesetWord, marks: WordLayer.Marks?) {
        let text = item.focusText
        let pivot = Pivot.index(in: text, rule: prefs.pivotMode == .optimal ? .optimal : .middle)
        var wordStyle = style
        var word = Typesetter.typeset(text, pivot: pivot, style: wordStyle)

        var markPair: (open: String, close: String)?
        if let enclosure = item.enclosure { markPair = TextShaping.marks(for: enclosure) }
        func makeMarks(_ s: WordStyle) -> WordLayer.Marks? {
            guard let markPair else { return nil }
            let dim = palette.text.withAlphaComponent(0.3)
            var light = s
            light.font = NSFont.systemFont(ofSize: s.font.pointSize, weight: .light)
            light.pivotFont = light.font
            return WordLayer.Marks(
                open: Typesetter.typeset(markPair.open, pivot: 0, style: light, textColor: dim, highlight: false),
                close: Typesetter.typeset(markPair.close, pivot: 0, style: light, textColor: dim, highlight: false),
                gap: s.font.pointSize * 0.14)
        }
        var marks = makeMarks(wordStyle)

        // Shrink words (and their marks) that wouldn't fit on either side of the pivot.
        let half = bounds.width / 2 - 14
        let markRoom = marks.map { max($0.open.width, $0.close.width) + $0.gap } ?? 0
        let need = max(word.pivotCenter, word.width - word.pivotCenter) + markRoom
        if need > half, half > 0 {
            wordStyle = style.scaled(max(half / need, 0.25))
            word = Typesetter.typeset(text, pivot: pivot, style: wordStyle)
            marks = makeMarks(wordStyle)
        }
        return (word, marks)
    }

    private func renderItem() {
        guard let session else {
            [wordLayer, titleLayer, messageLayer, dotLayer, imageLayer, countdownLayer].forEach { $0.isHidden = true }
            return
        }
        switch session.state {
        case .loading:
            wordLayer.isHidden = true
            titleLayer.isHidden = true
            messageLayer.isHidden = true
            hideImage()
            setDot(visible: true)
        case .failed(let message):
            setDot(visible: false)
            wordLayer.isHidden = true
            titleLayer.isHidden = true
            hideImage()
            messageLayer.string = message
            messageLayer.isHidden = false
        case .paused, .playing, .finished:
            messageLayer.isHidden = true
            guard let item = session.currentItem else { return }
            switch item.kind {
            case .word:
                hideImage()
                titleLayer.isHidden = true
                setDot(visible: false)
                let set = typeset(item)
                wordLayer.word = set.word
                wordLayer.marks = set.marks
                wordLayer.isHidden = ribbonVisible
                if ribbonVisible { ribbon.highlighted = session.index }
                if session.state != .playing, !ribbonVisible { showRibbon(animated: false) }
                setAccessibilityValue(item.text)
            case .title:
                hideImage()
                setDot(visible: false)
                if ribbonVisible { hideRibbon(animated: false) }
                wordLayer.isHidden = true
                if titleLayer.isHidden || (titleLayer.string as? String) != item.text {
                    titleLayer.string = item.text
                    titleLayer.isHidden = false
                    fadeIn(titleLayer, duration: 0.25)
                }
            case .image:
                if ribbonVisible { hideRibbon(animated: false) }
                wordLayer.isHidden = true
                titleLayer.isHidden = true
                showImage(item, at: session.index)
            }
        }
        updateProgressBar()
    }

    private func renderChrome() {
        guard let session else {
            infoLayer.opacity = 0
            progressLayer.isHidden = true
            guideTop.isHidden = true
            guideBottom.isHidden = true
            return
        }
        let isWord = session.currentItem?.kind == .word && !isTerminal(session.state)
        guideTop.isHidden = !(prefs.showGuides && isWord)
        guideBottom.isHidden = guideTop.isHidden

        // With the bottom chrome, the info line only carries the held-image hint.
        let showInfo = !isPreview && !timelineActive
            && (bar == nil ? (session.state == .paused || session.state == .finished || session.isHoldingImage)
                           : session.isHoldingImage)
        if showInfo { infoLayer.string = infoText() }
        setOpacity(infoLayer, showInfo ? 1 : 0, duration: showInfo ? 0.3 : 0.15)
        updateProgressBar()
    }

    private func isTerminal(_ state: ReaderSession.State) -> Bool {
        if case .failed = state { return true }
        return state == .loading
    }

    private func updateProgressBar() {
        guard let session, !session.stream.isEmpty else {
            progressLayer.isHidden = true
            return
        }
        var visible: Bool
        switch prefs.progressVisibility {
        case .always: visible = true
        case .paused: visible = session.state != .playing
        case .never: visible = false
        }
        if controlsVisible { visible = false }
        progressLayer.isHidden = !visible
        guard visible else { return }
        let width = (bounds.width * session.progress).rounded()
        progressLayer.frame = CGRect(x: 0, y: 0, width: width, height: timelineActive ? 3 : 2)
    }

    private func infoText() -> String {
        guard let session else { return "" }
        if session.isHoldingImage { return "Press → to continue" }
        var parts: [String] = []
        if !session.title.isEmpty { parts.append(session.title) }
        if let chapter = session.stream.chapter(at: session.index), chapter.title != session.title {
            parts.append(chapter.title)
        }
        if session.state == .finished {
            parts.append("Finished")
            parts.append("Space to read again")
        } else if bar != nil {
            // Progress, time and speed live in the control bar.
        } else {
            parts.append("\(Int((session.progress * 100).rounded()))%")
            if remaining?.index != session.index {
                remaining = (session.index, session.remainingSeconds)
            }
            if let seconds = remaining?.seconds { parts.append(Self.formatRemaining(seconds)) }
            let effective = Int(session.pacer.effectiveWPM.rounded())
            parts.append(abs(effective - prefs.wpm) >= 5 ? "\(effective) wpm adaptive" : "\(prefs.wpm) wpm")
        }
        return parts.joined(separator: "  ·  ")
    }

    static func formatRemaining(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) sec left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min left" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr left" : "\(h) hr \(m) min left"
    }

    private func setDot(visible: Bool) {
        guard dotLayer.isHidden == visible else { return }
        dotLayer.isHidden = !visible
        if visible {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.22
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dotLayer.add(pulse, forKey: "pulse")
        } else {
            dotLayer.removeAnimation(forKey: "pulse")
        }
    }

    // MARK: - Ribbon

    private func buildRibbon(anchor: Int) {
        guard let session, session.stream.items.indices.contains(anchor),
              session.stream[anchor].kind == .word, bounds.width > 0 else {
            ribbon.entries = []
            return
        }
        let stream = session.stream
        let rule: PivotRule = prefs.pivotMode == .optimal ? .optimal : .middle
        let dim = palette.text.withAlphaComponent(0.34)
        let space = (" " as NSString).size(withAttributes: [.font: style.font]).width
        let reach = bounds.width * 1.5

        func entry(_ i: Int, pivotX: (TypesetWord) -> CGFloat) -> RibbonLayer.Entry {
            let text = stream[i].text
            let pivot = Pivot.index(in: text, rule: rule)
            let word = Typesetter.typeset(text, pivot: pivot, style: style, textColor: dim, highlight: false)
            return RibbonLayer.Entry(index: i, text: text, pivot: pivot, word: word, pivotX: pivotX(word))
        }

        var entries = [entry(anchor) { _ in 0 }]
        var right = entries[0].right
        var i = anchor + 1
        while i < stream.count, stream[i].kind == .word, right < reach, entries.count < 500 {
            let gap = stream[i].paragraph != stream[i - 1].paragraph ? space * 3 : (stream[i].spaceBefore ? space : 0)
            let left = right + gap
            let e = entry(i) { left + $0.pivotCenter }
            entries.append(e)
            right = e.right
            i += 1
        }
        var left = entries[0].left
        i = anchor - 1
        var head: [RibbonLayer.Entry] = []
        while i >= 0, stream[i].kind == .word, left > -reach, head.count < 500 {
            let gap = stream[i].paragraph != stream[i + 1].paragraph ? space * 3 : (stream[i + 1].spaceBefore ? space : 0)
            let rightEdge = left - gap
            let e = entry(i) { rightEdge - $0.width + $0.pivotCenter }
            head.append(e)
            left = e.left
            i -= 1
        }
        ribbon.entries = head.reversed() + entries
        ribbon.highlighted = session.index
    }

    private func showRibbon(animated: Bool) {
        guard let session, session.currentItem?.kind == .word, !ribbonVisible else { return }
        ribbonGeneration += 1
        ribbonVisible = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buildRibbon(anchor: session.index)
        ribbon.shift = 0
        ribbon.removeAllAnimations()
        ribbon.opacity = 1
        ribbon.isHidden = false
        wordLayer.isHidden = true
        CATransaction.commit()

        guard animated, !reduceMotion, bounds.width > 0 else { return }
        let wordWidth = wordLayer.word?.width ?? 80
        let start = min(1, (wordWidth + 28) / (0.76 * bounds.width))
        let reveal = CABasicAnimation(keyPath: "transform.scale.x")
        reveal.fromValue = start
        reveal.toValue = 1
        reveal.duration = 0.55
        reveal.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        revealMask.add(reveal, forKey: "reveal")
    }

    private func hideRibbon(animated: Bool) {
        guard ribbonVisible else { return }
        ribbonVisible = false
        scrubbing = false
        shiftTween = nil
        snapWork?.cancel()
        ribbonGeneration += 1
        let generation = ribbonGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wordLayer.isHidden = false
        CATransaction.commit()
        guard animated, !reduceMotion else {
            ribbon.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.ribbonGeneration == generation else { return }
            self.ribbon.isHidden = true
            self.ribbon.opacity = 1
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        ribbon.opacity = 0
        ribbon.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Slides the ribbon so the current word sits on the center line.
    private func alignRibbon(animated: Bool) {
        guard let session else { return }
        guard let entry = ribbon.entries.first(where: { $0.index == session.index }) else {
            buildRibbon(anchor: session.index)
            ribbon.shift = 0
            return
        }
        rebuildIfNearEdge(around: entry)
        guard let current = ribbon.entries.first(where: { $0.index == session.index }) else { return }
        let target = -current.pivotX
        if animated, !reduceMotion {
            shiftTween = Tween(from: ribbon.shift, to: target, start: CACurrentMediaTime(), duration: 0.26)
            updateDisplayLink()
        } else {
            ribbon.shift = target
        }
    }

    /// Re-anchors the ribbon on `entry` when it gets close to either end, without moving anything on screen.
    private func rebuildIfNearEdge(around entry: RibbonLayer.Entry) {
        guard let session, let first = ribbon.entries.first, let last = ribbon.entries.last else { return }
        let stream = session.stream
        let moreBefore = first.index > 0 && stream[first.index - 1].kind == .word
        let moreAfter = last.index < stream.count - 1 && stream[last.index + 1].kind == .word
        let nearStart = moreBefore && entry.index - first.index < 14
        let nearEnd = moreAfter && last.index - entry.index < 14
        guard nearStart || nearEnd else { return }
        let offset = entry.pivotX
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buildRibbon(anchor: entry.index)
        ribbon.shift += offset
        if let tween = shiftTween {
            shiftTween = Tween(from: tween.from + offset, to: tween.to + offset,
                               start: tween.start, duration: tween.duration)
        }
        CATransaction.commit()
    }

    // MARK: - Scrubbing

    override func scrollWheel(with event: NSEvent) {
        guard let session, !session.stream.isEmpty, !isTerminal(session.state) else { return }
        if session.state == .playing { session.pause() }

        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let delta = abs(dx) >= abs(dy) ? dx : dy

        guard event.hasPreciseScrollingDeltas else {
            if delta != 0 { session.step(delta < 0 ? 1 : -1) }
            return
        }
        guard ribbonVisible, !ribbon.entries.isEmpty else {
            if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
                if abs(delta) > 2 { session.step(delta < 0 ? 1 : -1) }
            }
            return
        }

        if event.momentumPhase == .began { snapWork?.cancel() }
        if delta != 0 {
            scrubbing = true
            shiftTween = nil
            ribbon.shift = clampedShift(ribbon.shift + delta)
            followScrub()
        }
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            snap()
        } else if event.phase == .ended || event.phase == .cancelled {
            scheduleSnap(after: 0.08)
        } else if event.phase == [] && event.momentumPhase == [] {
            scheduleSnap(after: 0.18)
        }
    }

    private func clampedShift(_ proposed: CGFloat) -> CGFloat {
        guard let session, let first = ribbon.entries.first, let last = ribbon.entries.last else { return proposed }
        let maxShift = -first.pivotX
        let minShift = -last.pivotX
        let atStart = first.index == 0 || session.stream[first.index - 1].kind != .word
        let atEnd = last.index == session.stream.count - 1 || session.stream[last.index + 1].kind != .word
        if proposed > maxShift, atStart { return maxShift + (proposed - maxShift) * 0.3 }
        if proposed < minShift, atEnd { return minShift + (proposed - minShift) * 0.3 }
        return proposed
    }

    private func followScrub() {
        guard let session, let entry = ribbon.centeredEntry() else { return }
        if entry.index != session.index { session.seek(to: entry.index) }
        rebuildIfNearEdge(around: entry)
    }

    private func scheduleSnap(after delay: TimeInterval) {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.snap() }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func snap() {
        snapWork?.cancel()
        guard let session, let entry = ribbon.centeredEntry() else {
            scrubbing = false
            return
        }
        if entry.index != session.index { session.seek(to: entry.index) }
        shiftTween = Tween(from: ribbon.shift, to: -entry.pivotX, start: CACurrentMediaTime(),
                           duration: reduceMotion ? 0.01 : 0.34)
        updateDisplayLink()
    }

    // MARK: - Frame clock

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        session?.tick(now)
        if let tween = shiftTween {
            ribbon.shift = tween.value(at: now)
            if tween.isDone(at: now) {
                shiftTween = nil
                scrubbing = false
            }
        }
        updateCountdown(now)
        updateDisplayLink()
    }

    private func updateDisplayLink() {
        let needed = session?.state == .playing || shiftTween != nil
        if link?.isPaused == needed { link?.isPaused = !needed }
    }

    // MARK: - Images

    private func showImage(_ item: ReadingItem, at index: Int) {
        guard shownImageIndex != index else { return }
        shownImageIndex = index
        host?.readerView(self, imageBeatActive: true)
        if let image = images.cached(index) {
            present(image)
        } else if let asset = item.image {
            imageLayer.isHidden = true
            setDot(visible: true)
            images.load(asset, index: index) { [weak self] image in
                guard let self, self.shownImageIndex == index else { return }
                self.setDot(visible: false)
                if let image {
                    self.present(image)
                } else if self.session?.state == .playing {
                    self.session?.continueAfterImage()
                }
            }
        }
    }

    private func present(_ image: CGImage) {
        shownImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.frame = imageRect(for: image)
        imageLayer.isHidden = false
        CATransaction.commit()
        guard !reduceMotion else { return fadeIn(imageLayer, duration: 0.2) }
        let group = CAAnimationGroup()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.975
        scale.toValue = 1
        group.animations = [fade, scale]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        imageLayer.add(group, forKey: "in")
    }

    private func hideImage() {
        countdownLayer.isHidden = true
        guard shownImageIndex != nil else { return }
        shownImageIndex = nil
        shownImage = nil
        host?.readerView(self, imageBeatActive: false)
        guard !imageLayer.isHidden else { return }
        let snapshot = StillLayer()
        snapshot.contents = imageLayer.contents
        snapshot.frame = imageLayer.frame
        snapshot.cornerRadius = imageLayer.cornerRadius
        snapshot.cornerCurve = .continuous
        snapshot.masksToBounds = true
        snapshot.contentsGravity = .resize
        layer?.insertSublayer(snapshot, below: imageLayer)
        imageLayer.isHidden = true
        imageLayer.contents = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { snapshot.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = reduceMotion ? 0.12 : 0.22
        snapshot.opacity = 0
        snapshot.add(fade, forKey: "out")
        CATransaction.commit()
    }

    private func imageRect(for image: CGImage) -> CGRect {
        let area = bounds.insetBy(dx: 28, dy: 30)
        guard area.width > 0, area.height > 0, image.width > 0, image.height > 0 else { return .zero }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(area.width / w, area.height / h, 2)
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        return CGRect(x: (bounds.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private func updateCountdown(_ now: CFTimeInterval) {
        guard let session, session.currentItem?.kind == .image, shownImage != nil,
              let p = session.beatProgress(at: now) else {
            if !countdownLayer.isHidden { countdownLayer.isHidden = true }
            return
        }
        let full: CGFloat = 120
        let width = (full * CGFloat(1 - p)).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        countdownLayer.isHidden = false
        countdownLayer.frame = CGRect(x: bounds.midX - width / 2, y: 12, width: width, height: 2)
        CATransaction.commit()
    }

    // MARK: - Small animation helpers

    private func fadeIn(_ layer: CALayer, duration: CFTimeInterval) {
        guard !reduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fadeIn")
    }

    private func setOpacity(_ layer: CALayer, _ value: Float, duration: CFTimeInterval) {
        guard layer.opacity != value else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = value
        CATransaction.commit()
        guard !reduceMotion else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = value
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "opacity")
    }

    /// A brief notice at the top ("450 wpm"). Hidden in previews.
    func flash(_ text: String) {
        guard !isPreview else { return }
        hudWork?.cancel()
        hudLayer.string = text
        setOpacity(hudLayer, 1, duration: 0.12)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setOpacity(self.hudLayer, 0, duration: 0.35)
        }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    // MARK: - Shortcuts overlay

    private func toggleHelp() {
        if helpView == nil { showHelp() } else { hideHelp() }
    }

    private func showHelp() {
        guard !isPreview, helpView == nil else { return }
        session?.pause()
        let view = NSHostingView(rootView: ShortcutsOverlay(background: Color(nsColor: palette.background),
                                                            foreground: Color(nsColor: palette.text),
                                                            accent: Color(nsColor: palette.pivot)))
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        view.alphaValue = 0
        addSubview(view)
        helpView = view
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : 0.2
            view.animator().alphaValue = 1
        }
    }

    private func hideHelp() {
        guard let view = helpView else { return }
        helpView = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : 0.15
            view.animator().alphaValue = 0
        }, completionHandler: { view.removeFromSuperview() })
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard !isPreview else { return super.keyDown(with: event) }
        if handleKey(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isPreview, event.type == .keyDown, window?.firstResponder === self,
              event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        return handleKey(event) || super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        escape()
    }

    private func escape() {
        if findBar != nil { return closeFind() }
        if helpView != nil { return hideHelp() }
        if pageView != nil { return closePage() }
        if host?.isFullScreen == true { return toggleFullScreen() }
        host?.readerViewRequestsClose(self)
    }

    fileprivate func changeSpeed(by delta: Int) {
        let new = min(max(prefs.wpm + delta, Preferences.wpmRange.lowerBound), Preferences.wpmRange.upperBound)
        prefs.wpm = new
        flash("\(new) wpm")
        updateTimeText(force: true)
    }

    private func changeTextScale(by delta: Double?) {
        let new = delta.map { prefs.textScale + $0 } ?? 1
        prefs.textScale = min(max(new, Preferences.textScaleRange.lowerBound), Preferences.textScaleRange.upperBound)
        flash("Text \(Int((prefs.textScale * 100).rounded()))%")
    }

    /// Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if command {
            switch chars {
            case "w": host?.readerViewRequestsClose(self)
            case "q": NSApp.terminate(nil)
            case ",": SettingsWindowController.shared.show()
            case "o": ReadingCoordinator.shared.presentOpenPanel()
            case "v": ReadingCoordinator.shared.readClipboard()
            case "1": host?.readerView(self, requestsSize: .compact)
            case "2": host?.readerView(self, requestsSize: .regular)
            case "3": host?.readerView(self, requestsSize: .large)
            case "=", "+": changeTextScale(by: 0.1)
            case "-": changeTextScale(by: -0.1)
            case "0": changeTextScale(by: nil)
            case "[": session?.jumpChapter(forward: false)
            case "]": session?.jumpChapter(forward: true)
            case "f" where flags.contains(.control): toggleFullScreen()
            case "f": showFind()
            case "g": findNext(forward: !shift)
            case "e": toggleEditing()
            case "n": ReadingCoordinator.shared.compose()
            case "\r":
                if pageView?.isEditing == true {
                    finishEditing()
                    closePage()
                    session?.play()
                } else {
                    return false
                }
            default:
                switch event.keyCode {
                case 123: session?.jumpChapter(forward: false)
                case 124: session?.jumpChapter(forward: true)
                case 126: session?.seekToStart(); flash("Beginning")
                case 125: session?.seekToEnd(); flash("End")
                default: return false
                }
            }
            return true
        }

        guard let session else {
            if event.keyCode == 53 { escape(); return true }
            return false
        }

        switch event.keyCode {
        case 49, 36, 76: // space, return, enter
            if session.isHoldingImage { session.continueFromHold() } else { session.togglePlayback() }
        case 53:
            escape()
        case 123, 124: // ← →
            let forward = event.keyCode == 124
            if forward, session.isHoldingImage { session.continueFromHold(); return true }
            if option {
                session.jumpParagraph(forward: forward)
            } else if session.state == .playing {
                session.jumpSentence(forward: forward)
            } else {
                session.step((forward ? 1 : -1) * (shift ? 5 : 1))
            }
        case 126: changeSpeed(by: shift ? 100 : 25)
        case 125: changeSpeed(by: shift ? -100 : -25)
        case 115: session.seekToStart(); flash("Beginning")
        case 119: session.seekToEnd(); flash("End")
        case 48: togglePage()
        default:
            switch chars {
            case "f": toggleFullScreen()
            case "?", "/": toggleHelp()
            default: return false
            }
        }
        return true
    }

    /// ⌘C copies the sentence you're on.
    @objc func copy(_ sender: Any?) {
        guard let session, !session.stream.isEmpty else { return }
        let stream = session.stream
        var i = stream.sentenceStart(at: session.index)
        let sentence = stream[i].sentence
        var text = ""
        while i < stream.count, stream[i].sentence == sentence {
            if stream[i].kind == .word {
                if !text.isEmpty, stream[i].spaceBefore { text += " " }
                text += stream[i].sourceText
            }
            i += 1
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied sentence")
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if isPreview {
            session?.togglePlayback()
            return
        }
        guard let window else { return }
        if event.clickCount == 2 {
            // The first click already toggled playback; undo it and go full screen.
            session?.togglePlayback()
            toggleFullScreen()
            return
        }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                click(at: convert(event.locationInWindow, from: nil))
                return
            }
            let p = next.locationInWindow
            if hypot(p.x - start.x, p.y - start.y) > 3 {
                if host?.isFullScreen != true { window.performDrag(with: event) }
                return
            }
        }
    }

    private func click(at point: CGPoint) {
        guard let session else { return }
        if helpView != nil { return hideHelp() }
        if session.isHoldingImage { return session.continueFromHold() }
        if ribbonVisible, ribbon.frame.contains(point),
           let entry = ribbon.entry(atScreenX: point.x), entry.index != session.index {
            session.seek(to: entry.index)
            return
        }
        session.togglePlayback()
    }
}

extension ReaderSession {
    /// Skips an image that failed to load.
    func continueAfterImage() {
        if currentItem?.kind == .image { step(1) }
    }
}

// MARK: - Controls

extension ReaderView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        revealControls()
        let p = convert(event.locationInWindow, from: nil)
        setCloseButton(visible: p.x < 90 && p.y > bounds.height - 70)
    }

    override func mouseEntered(with event: NSEvent) { revealControls() }

    override func mouseExited(with event: NSEvent) {
        setCloseButton(visible: false)
        if session?.state == .playing, !timelineDragging { setControls(visible: false) }
    }

    private func makeCloseButton() -> CloseButton {
        CloseButton(palette: palette) { [weak self] in
            guard let self else { return }
            self.host?.readerViewRequestsClose(self)
        }
    }

    private func setCloseButton(visible: Bool) {
        #if DEBUG
        if pinCloseForDebug, !visible { return }
        #endif
        guard let button = closeButton, (button.alphaValue > 0.5) != visible else { return }
        if visible { button.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : (visible ? 0.2 : 0.4)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: {
            if button.alphaValue == 0 { button.isHidden = true }
        })
    }

    private func installControlsIfNeeded() {
        guard !isPreview, bar == nil else { return }
        barModel.session = session
        barModel.palette = palette
        barModel.onSeek = { [weak self] fraction in
            guard let self, let session = self.session else { return }
            session.seek(to: self.timelineIndex(fraction: fraction))
        }
        barModel.onScrubbing = { [weak self] active in
            guard let self else { return }
            self.timelineDragging = active
            if !active, self.ribbonVisible { self.alignRibbon(animated: false) }
        }
        barModel.onHover = { [weak self] fraction in self?.showTimelinePreview(fraction) }
        barModel.onSpeedChange = { [weak self] delta in self?.changeSpeed(by: delta) }
        let view = NSHostingView(rootView: ReaderChrome(model: barModel))
        view.safeAreaRegions = []
        view.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        view.autoresizingMask = [.width, .maxYMargin]
        view.alphaValue = 0
        view.isHidden = true
        addSubview(view)
        bar = view
        let close = NSHostingView(rootView: makeCloseButton())
        // The × sits the same distance from the top edge as from the left edge.
        close.frame = NSRect(x: Self.closeInset - 15, y: bounds.height - Self.closeInset - 15, width: 30, height: 30)
        close.safeAreaRegions = []
        close.autoresizingMask = [.maxXMargin, .minYMargin]
        close.alphaValue = 0
        close.isHidden = true
        addSubview(close)
        closeButton = close
        needsLayout = true
        setControls(visible: session?.state != .playing, animated: false)
    }

    /// Shows the controls; while reading they fade away again after a moment of stillness.
    private func revealControls() {
        guard bar != nil else { return }
        controlsHideWork?.cancel()
        setControls(visible: true)
        guard session?.state == .playing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session?.state == .playing, !self.timelineDragging else { return }
            // Keep them while the pointer rests on the bar.
            if let bar = self.bar, let window = self.window,
               bar.frame.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                return self.revealControls()
            }
            self.setControls(visible: false)
        }
        controlsHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func setControls(visible: Bool, animated: Bool = true) {
        guard let bar else { return }
        if !visible { controlsHideWork?.cancel() }
        guard controlsVisible != visible else { return }
        controlsVisible = visible
        if visible { bar.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated && !reduceMotion ? (visible ? 0.25 : 0.5) : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !self.controlsVisible else { return }
            bar.isHidden = true
        })
        if !visible { showTimelinePreview(nil) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        renderChrome()
        CATransaction.commit()
    }

    func toggleFullScreen() {
        host?.readerViewRequestsFullScreen(self)
    }

    private func updateTimeText(force: Bool) {
        guard let session, !session.stream.isEmpty else {
            barModel.timeText = ""
            barModel.title = session?.title ?? ""
            return
        }
        let now = CACurrentMediaTime()
        guard force || now - lastTimeTextUpdate > 1 else { return }
        lastTimeTextUpdate = now
        var title = session.title
        if let chapter = session.stream.chapter(at: session.index), chapter.title != title {
            title = title.isEmpty ? chapter.title : title + "  —  " + chapter.title
        }
        barModel.title = title
        if session.state == .finished {
            barModel.timeText = "Finished  ·  Space to read again"
            return
        }
        if remaining?.index != session.index || force {
            remaining = (session.index, session.remainingSeconds)
        }
        let percent = Int((session.progress * 100).rounded())
        barModel.timeText = "\(percent)%  ·  " + Self.formatRemaining(remaining?.seconds ?? 0)
    }

    private func timelineIndex(fraction: Double) -> Int {
        guard let session, session.stream.count > 1 else { return 0 }
        let total = session.isIngesting && session.ingestProgress > 0
            ? Double(session.stream.count) / max(session.ingestProgress, 0.01)
            : Double(session.stream.count - 1)
        return min(Int((min(max(fraction, 0), 1) * total).rounded()), session.stream.count - 1)
    }

    /// The words at a point on the timeline, shown just above the bar while hovering it.
    private func showTimelinePreview(_ fraction: Double?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let fraction, let session, !session.stream.isEmpty else {
            hoverLabel.isHidden = true
            barModel.previewText = nil
            if timelineActive { timelineActive = false; renderChrome() }
            return
        }
        let index = timelineIndex(fraction: fraction)
        var words: [String] = []
        var i = index
        while i < session.stream.count, words.count < 7 {
            let item = session.stream[i]
            if item.kind == .word { words.append(item.sourceText) } else if !words.isEmpty { break }
            i += 1
        }
        var text = words.joined(separator: " ")
        if let chapter = session.stream.chapter(at: index) { text = chapter.title + "  —  " + text }
        let percent = Int((fraction * 100).rounded())
        barModel.previewText = text.isEmpty ? "\(percent)%" : "\(text)…  ·  \(percent)%"
        if !timelineActive { timelineActive = true; renderChrome() }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isPreview, let session else { return nil }
        let menu = NSMenu()
        func add(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], enabled: Bool = true,
                 checked: Bool = false, to target: NSMenu? = nil, _ action: @escaping @MainActor () -> Void) {
            let item = ActionMenuItem(title: title, key: key, action: action)
            item.keyEquivalentModifierMask = modifiers
            item.isEnabled = enabled
            item.state = checked ? .on : .off
            (target ?? menu).addItem(item)
        }
        menu.autoenablesItems = false
        add(session.state == .playing ? "Pause" : "Play", key: " ") { session.togglePlayback() }
        add("Previous Sentence") { session.jumpSentence(forward: false) }
        add("Next Sentence") { session.jumpSentence(forward: true) }
        menu.addItem(.separator())

        let speed = NSMenu()
        for value in [150, 200, 250, 300, 350, 400, 450, 500, 600, 700, 800, 1000] {
            add("\(value) wpm", checked: prefs.wpm == value, to: speed) { [weak self] in
                guard let self else { return }
                self.changeSpeed(by: value - self.prefs.wpm)
            }
        }
        speed.addItem(.separator())
        add("Adaptive Speed", checked: prefs.adaptiveSpeed, to: speed) { [weak self] in
            guard let self else { return }
            self.prefs.adaptiveSpeed.toggle()
        }
        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speed
        menu.addItem(speedItem)

        add("Page View", key: "\t", checked: pageView != nil) { [weak self] in self?.togglePage() }
        add("Find…", key: "f", modifiers: .command) { [weak self] in self?.showFind() }
        add("Edit Text", key: "e", modifiers: .command, enabled: session.isEditable) { [weak self] in self?.toggleEditing() }
        add("Copy Sentence", key: "c", modifiers: .command) { [weak self] in self?.copy(nil) }
        menu.addItem(.separator())

        let size = NSMenu()
        for preset in WindowSizePreset.allCases {
            add(preset.label, key: "\(preset.rawValue)", modifiers: .command, to: size) { [weak self] in
                guard let self else { return }
                self.host?.readerView(self, requestsSize: preset)
            }
        }
        size.addItem(.separator())
        add("Larger Text", key: "+", modifiers: .command, to: size) { [weak self] in self?.changeTextScale(by: 0.1) }
        add("Smaller Text", key: "-", modifiers: .command, to: size) { [weak self] in self?.changeTextScale(by: -0.1) }
        add("Actual Size", key: "0", modifiers: .command, to: size) { [weak self] in self?.changeTextScale(by: nil) }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = size
        menu.addItem(sizeItem)
        add(host?.isFullScreen == true ? "Exit Full Screen" : "Full Screen", key: "f") { [weak self] in self?.toggleFullScreen() }
        menu.addItem(.separator())
        add("Keyboard Shortcuts", key: "?") { [weak self] in self?.toggleHelp() }
        add("Library", key: "0", modifiers: [.command, .option]) { LibraryWindowController.shared.show() }
        add("Settings…", key: ",", modifiers: .command) { SettingsWindowController.shared.show() }
        add("Close", key: "w", modifiers: .command) { [weak self] in
            guard let self else { return }
            self.host?.readerViewRequestsClose(self)
        }
        return menu
    }
}

/// A menu item that runs a closure.
nonisolated final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, key: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}

// MARK: - Page

extension ReaderView {
    var isPageMode: Bool { pageView != nil }

    private func pageFont() -> NSFont {
        let size = max(15, min(21, bounds.width / 44)) * CGFloat(prefs.textScale)
        return prefs.fontFamily.isEmpty
            ? NSFont.systemFont(ofSize: size, weight: .regular)
            : prefs.font(size: size)
    }

    func togglePage() {
        if pageView == nil { openPage(editing: false) } else { closePage() }
    }

    func openPage(editing: Bool) {
        guard !isPreview, let session else { return }
        if let page = pageView {
            if editing, session.isEditable { page.beginEditing(at: session.index) }
            return
        }
        showTimelinePreview(nil)
        let page = PageView(frame: bounds)
        page.autoresizingMask = [.width, .height]
        page.layer?.backgroundColor = palette.background.cgColor
        page.apply(palette: palette, font: pageFont())
        page.load(session.stream, reset: true)
        pageGeneration = session.contentGeneration
        page.onSelectItem = { [weak self] index in self?.session?.seek(to: index) }
        page.keyHandler = { [weak self] event in self?.handlePageKey(event) ?? false }
        page.alphaValue = 0
        if let bar { addSubview(page, positioned: .below, relativeTo: bar) }
        else if let find = findBar { addSubview(page, positioned: .below, relativeTo: find) }
        else { addSubview(page) }
        pageView = page

        page.highlight(session.index, scroll: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : 0.22
            page.animator().alphaValue = 1
        }
        if editing, session.isEditable {
            page.beginEditing(at: session.index)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    func closePage() {
        guard let page = pageView else { return }
        if page.isEditing { finishEditing() }
        pageView = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : 0.18
            page.animator().alphaValue = 0
        }, completionHandler: { page.removeFromSuperview() })
        window?.makeFirstResponder(self)
        renderAll()
    }

    private func syncPage() {
        guard let page = pageView, let session, !page.isEditing else { return }
        let replaced = session.contentGeneration != pageGeneration
        pageGeneration = session.contentGeneration
        page.load(session.stream, reset: replaced)
        page.highlight(session.index, scroll: replaced)
    }

    /// Keys typed while the page has focus. Returns true when handled.
    private func handlePageKey(_ event: NSEvent) -> Bool {
        guard let page = pageView else { return false }
        if page.isEditing {
            let command = event.modifierFlags.contains(.command)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if event.keyCode == 53 || (command && chars == "e") {
                finishEditing()
                return true
            }
            if command, chars == "\r" {
                finishEditing()
                closePage()
                session?.play()
                return true
            }
            if command, chars == "w" { host?.readerViewRequestsClose(self); return true }
            return false
        }
        return handleKey(event)
    }

    private func toggleEditing() {
        guard let session, session.isEditable else {
            flash("Only pasted text can be edited")
            return
        }
        if let page = pageView, page.isEditing {
            finishEditing()
        } else {
            session.pause()
            openPage(editing: true)
        }
    }

    private func finishEditing() {
        guard let page = pageView, page.isEditing else { return }
        let result = page.endEditing()
        ReadingCoordinator.shared.applyEdit(text: result.text, atWord: result.wordsBeforeCaret)
        syncPage()
        window?.makeFirstResponder(self)
    }
}

// MARK: - Find

extension ReaderView {
    func showFind() {
        guard !isPreview, session != nil else { return }
        if let bar = findBar { return bar.focus() }
        session?.pause()
        let width: CGFloat = min(320, bounds.width - 32)
        let bar = FindBar(frame: NSRect(x: (bounds.midX - width / 2).rounded(), y: bounds.height - 46, width: width, height: 30))
        bar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        bar.apply(palette)
        bar.onChange = { [weak self] query in self?.find(query) }
        bar.onNext = { [weak self] forward in self?.findNext(forward: forward) }
        bar.onClose = { [weak self] in self?.closeFind() }
        bar.alphaValue = 0
        addSubview(bar)
        findBar = bar
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : 0.18
            bar.animator().alphaValue = 1
        }
        bar.focus()
    }

    #if DEBUG
    func debugFind(_ query: String) { find(query) }
    func debugShowClose() {
        pinCloseForDebug = true
        setCloseButton(visible: true)
    }
    func debugType(_ text: String) {
        pageView?.debugInsert(text)
        finishEditing()
    }
    func debugTimeline(at fraction: CGFloat) { showTimelinePreview(Double(fraction)) }
    #endif

    private func find(_ query: String) {
        guard let session else { return }
        findMatches = session.stream.matches(for: query)
        let from = session.index
        findCurrent = findMatches.firstIndex { $0 >= from } ?? (findMatches.isEmpty ? nil : 0)
        if let current = findCurrent { session.seek(to: findMatches[current]) }
        findBar?.setCount(current: findCurrent, total: findMatches.count)
    }

    func findNext(forward: Bool) {
        guard let session else { return }
        if findBar == nil { return showFind() }
        if findMatches.isEmpty, let query = findBar?.query, !query.isEmpty { find(query) }
        guard !findMatches.isEmpty else { return }
        let count = findMatches.count
        let current = findCurrent ?? (forward ? -1 : 0)
        let next = ((current + (forward ? 1 : -1)) % count + count) % count
        findCurrent = next
        session.seek(to: findMatches[next])
        findBar?.setCount(current: next, total: count)
    }

    private func closeFind() {
        guard let bar = findBar else { return }
        findBar = nil
        findMatches = []
        findCurrent = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : 0.14
            bar.animator().alphaValue = 0
        }, completionHandler: { bar.removeFromSuperview() })
        window?.makeFirstResponder(self)
    }
}
