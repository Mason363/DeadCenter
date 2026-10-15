import AppKit
import DCModel
import DCEngine

/// The whole text, laid out like a page. The current word is highlighted; clicking a word moves
/// the reader there. Text sources can be edited in place.
final class PageView: NSView, NSTextViewDelegate {
    var onSelectItem: ((Int) -> Void)?
    var onEditingChanged: (() -> Void)?
    /// Sees key events before the text view; return true to consume.
    var keyHandler: ((NSEvent) -> Bool)? {
        didSet { textView.keyHandler = keyHandler }
    }

    private let scrollView = NSScrollView()
    /// Fades the text out at the page's top and bottom edges instead of cutting it off under the controls.
    private let edgeFade = CAGradientLayer()
    private let hint = NSTextField(labelWithString: "Paste or type  ·  ⌘↩ to read  ·  Esc when done")
    /// "Loading…" while the page waits for its first words.
    private let placeholder = NSTextField(labelWithString: "")
    private let textView = PageTextView()
    private var itemRanges: [NSRange] = []
    private var itemIndices: [Int] = []
    private var builtCount = 0
    private var highlighted: NSRange?
    private var palette: ReaderPalette = .dark
    private var bodyFont = NSFont.systemFont(ofSize: 18)
    private var lastParagraph = -1
    /// Page images are drawn at text width, so they don't need the reader's full resolution.
    private let images = ImageLoader(maxPixelSize: 1400)
    /// Images not loaded yet; they load as they come near the visible part of the page.
    private var pendingImages: [(attachment: NSTextAttachment, asset: ImageAsset, index: Int, location: Int)] = []
    private(set) var isEditing = false
    private var textBeforeEditing = ""
    /// True while the user has scrolled away; following resumes on the next jump, on play, or
    /// once the current word is back in view.
    private var userScrolled = false
    /// Top of the line the page last scrolled to while following playback.
    private var followedLineY: CGFloat?
    /// While playing, the page glides line by line so the current word stays at the same height.
    var isPlaying = false {
        didSet {
            guard isPlaying, !oldValue else { return }
            userScrolled = false
            followedLineY = nil
            if let highlighted { follow(highlighted) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.wantsLayer = true
        edgeFade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        scrollView.layer?.mask = edgeFade
        addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        if #available(macOS 15.0, *) { textView.writingToolsBehavior = .none }
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.delegate = self
        textView.onClick = { [weak self] index in self?.clicked(characterIndex: index) }
        scrollView.documentView = textView

        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.alignment = .center
        hint.isHidden = true
        hint.autoresizingMask = [.width, .minYMargin]
        hint.frame = NSRect(x: 0, y: bounds.height - 34, width: bounds.width, height: 16)
        addSubview(hint)

        placeholder.font = .systemFont(ofSize: 14, weight: .regular)
        placeholder.alignment = .center
        placeholder.isHidden = true
        placeholder.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        placeholder.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: bounds.width, height: 20)
        addSubview(placeholder)

        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // The page ends above the info line, so the two never overlap.
        scrollView.frame = NSRect(x: 0, y: ReaderView.barHeight, width: bounds.width,
                                  height: max(0, bounds.height - ReaderView.barHeight))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.frame = scrollView.bounds
        let edge = Double(min(22 / max(scrollView.bounds.height, 1), 0.2))
        edgeFade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        CATransaction.commit()
        updateInsets()
        loadVisibleImages()
    }

    private func updateInsets() {
        // A comfortable measure: ~70 characters, centered.
        let measure = min(bounds.width - 48, bodyFont.pointSize * 36)
        let side = max((bounds.width - measure) / 2, 24)
        textView.textContainerInset = NSSize(width: side, height: max(24, bounds.height * 0.1))
    }

    // MARK: - Content

    func apply(palette: ReaderPalette, font: NSFont) {
        self.palette = palette
        bodyFont = font
        hint.textColor = palette.text.withAlphaComponent(0.4)
        placeholder.textColor = palette.text.withAlphaComponent(0.45)
        textView.insertionPointColor = palette.pivot
        textView.selectedTextAttributes = [.backgroundColor: palette.pivot.withAlphaComponent(0.25)]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                let isHeading = (value as? NSFont)?.pointSize ?? 0 > font.pointSize * 1.05
                storage.addAttributes(attributes(heading: isHeading), range: range)
            }
            storage.endEditing()
        }
        textView.typingAttributes = attributes(heading: false)
        updateInsets()
    }

    private func attributes(heading: Bool) -> [NSAttributedString.Key: Any] {
        // Leading as line spacing, not a height multiple, so the editing caret matches the text.
        let style = NSMutableParagraphStyle()
        style.lineSpacing = bodyFont.pointSize * (heading ? 0.15 : 0.42)
        style.paragraphSpacing = bodyFont.pointSize * (heading ? 0.5 : 0.9)
        style.paragraphSpacingBefore = heading ? bodyFont.pointSize * 0.8 : 0
        let font = heading
            ? NSFontManager.shared.convert(bodyFont.withSize(bodyFont.pointSize * 1.35), toHaveTrait: .boldFontMask)
            : bodyFont
        return [
            .font: font,
            .foregroundColor: palette.text.withAlphaComponent(heading ? 1 : 0.86),
            .paragraphStyle: style,
        ]
    }

    func setPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
    }

    /// Rebuilds the page from the stream. Call again with the same stream to append newly streamed items.
    func load(_ stream: ReadingStream, reset: Bool) {
        guard let storage = textView.textStorage else { return }
        if reset {
            storage.setAttributedString(NSAttributedString())
            itemRanges = []
            itemIndices = []
            builtCount = 0
            lastParagraph = -1
            highlighted = nil
            images.reset()
            pendingImages = []
        }
        guard stream.count > builtCount else { return }
        let text = NSMutableAttributedString()
        let body = attributes(heading: false)
        let heading = attributes(heading: true)
        var offset = storage.length
        for i in builtCount..<stream.count {
            let item = stream[i]
            switch item.kind {
            case .word:
                let separator: String
                if offset == 0 { separator = "" }
                else if item.paragraph != lastParagraph { separator = "\n" }
                else { separator = item.spaceBefore ? " " : "" }
                if !separator.isEmpty {
                    text.append(NSAttributedString(string: separator, attributes: body))
                    offset += (separator as NSString).length
                }
                let word = item.sourceText
                let length = (word as NSString).length
                text.append(NSAttributedString(string: word, attributes: body))
                itemRanges.append(NSRange(location: offset, length: length))
                itemIndices.append(i)
                offset += length
                lastParagraph = item.paragraph
            case .title:
                let prefix = offset == 0 ? "" : "\n"
                text.append(NSAttributedString(string: prefix, attributes: body))
                offset += (prefix as NSString).length
                let length = (item.text as NSString).length
                text.append(NSAttributedString(string: item.text, attributes: heading))
                itemRanges.append(NSRange(location: offset, length: length))
                itemIndices.append(i)
                offset += length
                lastParagraph = -1
            case .image:
                guard let asset = item.image else { continue }
                let prefix = offset == 0 ? "" : "\n"
                text.append(NSAttributedString(string: prefix, attributes: body))
                offset += (prefix as NSString).length
                let attachment = NSTextAttachment()
                text.append(NSAttributedString(attachment: attachment))
                itemRanges.append(NSRange(location: offset, length: 1))
                itemIndices.append(i)
                offset += 1
                lastParagraph = -1
                pendingImages.append((attachment, asset, i, offset - 1))
            }
        }
        builtCount = stream.count
        storage.beginEditing()
        storage.append(text)
        storage.endEditing()
        DispatchQueue.main.async { [weak self] in self?.loadVisibleImages() }
    }

    @objc private func boundsChanged() {
        loadVisibleImages()
    }

    /// Loads images within a couple of screens of what's visible.
    private func loadVisibleImages() {
        guard !pendingImages.isEmpty, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let visible = scrollView.contentView.bounds
        let area = visible.insetBy(dx: 0, dy: -visible.height * 2)
        let glyphs = layoutManager.glyphRange(forBoundingRect: area, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let due = pendingImages.filter { NSLocationInRange($0.location, characters) }
        guard !due.isEmpty else { return }
        pendingImages.removeAll { NSLocationInRange($0.location, characters) }
        for image in due {
            images.load(image.asset, index: image.index) { [weak self] loaded in
                guard let self, let loaded else { return }
                self.setImage(loaded, for: image.attachment, at: image.location)
            }
        }
    }

    private func setImage(_ image: CGImage, for attachment: NSTextAttachment, at location: Int) {
        let width = min(CGFloat(image.width) / 2, bodyFont.pointSize * 34)
        let scale = width / CGFloat(image.width)
        attachment.image = NSImage(cgImage: image, size: NSSize(width: width, height: CGFloat(image.height) * scale))
        guard let storage = textView.textStorage, location < storage.length else { return }
        textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: location, length: 1),
                                                 actualCharacterRange: nil)
    }

    // MARK: - Highlight

    /// Highlights the item and keeps it in view unless the user has scrolled away.
    func highlight(_ index: Int, scroll: Bool) {
        guard let layoutManager = textView.layoutManager, !isEditing else { return }
        if let old = highlighted, NSMaxRange(old) <= (textView.textStorage?.length ?? 0) {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: old)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
        }
        guard let slot = slot(forItem: index) else { highlighted = nil; return }
        let range = itemRanges[slot]
        layoutManager.addTemporaryAttributes([
            .foregroundColor: palette.pivot,
        ], forCharacterRange: range)
        highlighted = range
        if scroll { userScrolled = false }
        if userScrolled, let rect = lineRect(for: range),
           scrollView.contentView.bounds.insetBy(dx: 0, dy: scrollView.contentView.bounds.height * 0.2).contains(rect) {
            userScrolled = false
        }
        guard !userScrolled else { return }
        if isPlaying && !scroll { follow(range) } else { reveal(range, animated: scroll) }
    }

    private func lineRect(for range: NSRange) -> NSRect? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }

    /// Keeps the current line a little above the middle, scrolling smoothly whenever it changes.
    private func follow(_ range: NSRange) {
        guard let rect = lineRect(for: range), rect.minY != followedLineY else { return }
        followedLineY = rect.minY
        let clip = scrollView.contentView
        let visible = clip.bounds
        let limit = max(textView.frame.height - visible.height, 0)
        let target = NSPoint(x: 0, y: min(max(rect.midY - visible.height * 0.38, 0), limit))
        guard abs(target.y - visible.minY) > 1 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || abs(target.y - visible.minY) > visible.height {
            clip.setBoundsOrigin(target)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.42
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }
        }
        scrollView.reflectScrolledClipView(clip)
    }

    private func reveal(_ range: NSRange, animated: Bool) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerOrigin.y
        let visible = scrollView.contentView.bounds
        let comfort = visible.insetBy(dx: 0, dy: visible.height * 0.25)
        guard !comfort.contains(rect) else { return }
        let target = NSPoint(x: 0, y: max(rect.midY - visible.height * 0.4, 0))
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(target)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func didScroll() {
        userScrolled = true
    }

    private func slot(forItem index: Int) -> Int? {
        // itemIndices is sorted; binary search for the item or the nearest one before it.
        var lo = 0, hi = itemIndices.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if itemIndices[mid] <= index { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    private func clicked(characterIndex: Int) {
        guard !isEditing, !itemRanges.isEmpty else { return }
        var lo = 0, hi = itemRanges.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if itemRanges[mid].location <= characterIndex { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        onSelectItem?(itemIndices[best])
    }

    // MARK: - Editing

    /// Turns editing on, placing the caret at the current word.
    func beginEditing(at index: Int) {
        guard !isEditing else { return }
        isEditing = true
        textBeforeEditing = textView.string
        if let old = highlighted {
            textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: old)
        }
        textView.isEditable = true
        let caret = slot(forItem: index).map { itemRanges[$0].location } ?? 0
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        window?.makeFirstResponder(textView)
        hint.isHidden = false
        onEditingChanged?()
    }

    /// Ends editing and returns the edited text plus the caret's word position (words before the caret).
    /// Ends editing: the text, how many whole words come before the caret, and whether anything changed.
    func endEditing() -> (text: String, wordsBeforeCaret: Int, changed: Bool) {
        isEditing = false
        textView.isEditable = false
        hint.isHidden = true
        let text = textView.string
        let caret = min(textView.selectedRange().location, (text as NSString).length)
        let before = (text as NSString).substring(to: caret)
        var words = before.split(whereSeparator: \.isWhitespace).count
        // A caret inside a word belongs to that word, not the next one.
        if let last = before.last, !last.isWhitespace, words > 0 { words -= 1 }
        onEditingChanged?()
        return (text, words, text != textBeforeEditing)
    }

    func focusText() {
        window?.makeFirstResponder(textView)
    }

    var isEmpty: Bool { textView.string.isEmpty }

    #if DEBUG
    func debugInsert(_ text: String) { textView.insertText(text, replacementRange: textView.selectedRange()) }
    func debugScroll(toCharacter location: Int) {
        textView.scrollRangeToVisible(NSRange(location: location, length: 1))
    }
    func debugScroll(to fraction: CGFloat) {
        let height = max(0, textView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: height * fraction))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    var debugPendingImages: String {
        let visible = scrollView.contentView.bounds
        var chars = NSRange()
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            chars = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: visible, in: tc), actualGlyphRange: nil)
        }
        return "highlight=\(highlighted.map(NSStringFromRange) ?? "-") line=\(highlighted.flatMap(lineRect(for:)).map(NSStringFromRect) ?? "-") playing=\(isPlaying) userScrolled=\(userScrolled) pending=\(pendingImages.count) vis=\(NSStringFromRect(visible)) frame=\(NSStringFromRect(textView.frame)) chars=\(NSStringFromRange(chars)) len=\(textView.textStorage?.length ?? 0) locs=\(pendingImages.map(\.location))"
    }
    #endif
}

/// Reports plain clicks (not drags or selections) as a character index, and lets the reader
/// see keys first so Space, arrows and Esc keep working on the page.
private final class PageTextView: NSTextView {
    var onClick: ((Int) -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard !isEditable, event.clickCount == 1, selectedRange().length == 0 else { return }
        onClick?(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let event = NSApp.currentEvent, keyHandler?(event) == true { return }
        super.cancelOperation(sender)
    }
}
