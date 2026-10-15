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
    private let hint = NSTextField(labelWithString: "Paste or type  ·  ⌘↩ to read  ·  Esc when done")
    private let textView = PageTextView()
    private var itemRanges: [NSRange] = []
    private var itemIndices: [Int] = []
    private var builtCount = 0
    private var highlighted: NSRange?
    private var palette: ReaderPalette = .dark
    private var bodyFont = NSFont.systemFont(ofSize: 18)
    private var lastParagraph = -1
    private let images = ImageLoader()
    private(set) var isEditing = false
    /// True while the user has scrolled away; following resumes on the next jump.
    private var userScrolled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: ReaderView.barHeight, right: 0)
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

        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateInsets()
    }

    private func updateInsets() {
        // A comfortable measure: ~70 characters, centered.
        let measure = min(bounds.width - 48, bodyFont.pointSize * 36)
        let side = max((bounds.width - measure) / 2, 24)
        textView.textContainerInset = NSSize(width: side, height: max(28, bounds.height * 0.12))
    }

    // MARK: - Content

    func apply(palette: ReaderPalette, font: NSFont) {
        self.palette = palette
        bodyFont = font
        hint.textColor = palette.text.withAlphaComponent(0.4)
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
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = heading ? 1.15 : 1.42
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
                images.load(asset, index: i) { [weak self] image in
                    guard let self, let image else { return }
                    self.setImage(image, for: attachment)
                }
            }
        }
        builtCount = stream.count
        storage.beginEditing()
        storage.append(text)
        storage.endEditing()
    }

    private func setImage(_ image: CGImage, for attachment: NSTextAttachment) {
        let width = min(CGFloat(image.width) / 2, bodyFont.pointSize * 34)
        let scale = width / CGFloat(image.width)
        attachment.image = NSImage(cgImage: image, size: NSSize(width: width, height: CGFloat(image.height) * scale))
        if let storage = textView.textStorage {
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if (value as? NSTextAttachment) === attachment {
                    textView.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                    stop.pointee = true
                }
            }
        }
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
        if !userScrolled { reveal(range, animated: scroll) }
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
    func endEditing() -> (text: String, wordsBeforeCaret: Int) {
        isEditing = false
        textView.isEditable = false
        hint.isHidden = true
        let text = textView.string
        let caret = min(textView.selectedRange().location, (text as NSString).length)
        let before = (text as NSString).substring(to: caret)
        let words = before.split(whereSeparator: \.isWhitespace).count
        onEditingChanged?()
        return (text, words)
    }

    func focusText() {
        window?.makeFirstResponder(textView)
    }

    var isEmpty: Bool { textView.string.isEmpty }

    #if DEBUG
    func debugInsert(_ text: String) { textView.insertText(text, replacementRange: textView.selectedRange()) }
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
