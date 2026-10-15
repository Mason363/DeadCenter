import AppKit
import SwiftUI

/// Colors and type for the transcript text.
struct TranscriptStyle: Equatable {
    var text: NSColor
    var font: NSFont

    var newest: NSColor { text }
    var older: NSColor { text.withAlphaComponent(0.58) }
    var tentative: NSColor { text.withAlphaComponent(0.34) }

    func attributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.18
        paragraph.paragraphSpacing = font.pointSize * 0.85
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }
}

/// The flowing transcript: a selectable, searchable text view that keeps to the newest line while
/// you're at the bottom and stays put once you scroll up.
struct TranscriptTextView: NSViewRepresentable {
    let segments: [TranscriptSegment]
    let tentative: String
    let generation: Int
    let style: TranscriptStyle
    @Binding var following: Bool
    let jumpRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(following: $following)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TranscriptScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        let text = NSTextView(usingTextLayoutManager: false)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.setAccessibilityLabel("Transcript")
        scroll.documentView = text

        context.coordinator.attach(scroll: scroll, text: text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.following = $following
        coordinator.render(segments: segments, tentative: tentative, generation: generation, style: style)
        if coordinator.lastJump != jumpRequest {
            coordinator.lastJump = jumpRequest
            coordinator.scrollToEnd(animated: true)
        }
    }

    final class Coordinator: NSObject {
        var following: Binding<Bool>
        var lastJump = 0

        private weak var scroll: NSScrollView?
        private weak var text: NSTextView?
        private var generation = -1
        private var style: TranscriptStyle?
        private var count = 0
        /// UTF-16 length of the confirmed text; the tentative tail follows it.
        private var confirmedLength = 0
        /// Where the newest sentence starts; everything before it is dimmed.
        private var brightStart = 0
        private var sentenceStart = 0
        private var lastText = ""

        init(following: Binding<Bool>) {
            self.following = following
        }

        func attach(scroll: NSScrollView, text: NSTextView) {
            self.scroll = scroll
            self.text = text
            (scroll as? TranscriptScrollView)?.onUserScroll = { [weak self] in self?.userScrolled() }
            scroll.postsFrameChangedNotifications = true
            text.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scroll)
            center.addObserver(self, selector: #selector(textGrew), name: NSView.frameDidChangeNotification, object: text)
            for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                center.addObserver(self, selector: #selector(userScrolled), name: name, object: scroll)
            }
            frameChanged()
        }

        func render(segments: [TranscriptSegment], tentative: String, generation: Int, style: TranscriptStyle) {
            guard let text, let storage = text.textStorage else { return }
            if generation != self.generation || style != self.style || segments.count < count {
                self.generation = generation
                self.style = style
                storage.setAttributedString(NSAttributedString())
                count = 0
                confirmedLength = 0
                brightStart = 0
                sentenceStart = 0
                lastText = ""
            }
            let renderedTentative = storage.length > confirmedLength
                ? (storage.string as NSString).substring(from: confirmedLength) : ""
            let separatorAndTentative = tentative.isEmpty ? "" : Transcript.separator(after: lastText, before: tentative) + tentative
            guard segments.count > count || renderedTentative != separatorAndTentative else { return }

            storage.beginEditing()
            storage.deleteCharacters(in: NSRange(location: confirmedLength, length: storage.length - confirmedLength))
            for segment in segments[count...] {
                let separator = lastText.isEmpty ? "" : segment.startsParagraph ? "\n" : Transcript.separator(after: lastText, before: segment.text)
                if segment.startsParagraph || lastText.isEmpty || Self.endsSentence(lastText) {
                    sentenceStart = confirmedLength + (separator as NSString).length
                }
                storage.append(NSAttributedString(string: separator + segment.text, attributes: style.attributes(style.newest)))
                confirmedLength = storage.length
                lastText = segment.text
            }
            count = segments.count
            if brightStart < sentenceStart {
                storage.addAttribute(.foregroundColor, value: style.older,
                                     range: NSRange(location: brightStart, length: sentenceStart - brightStart))
                brightStart = sentenceStart
            }
            if !separatorAndTentative.isEmpty {
                storage.append(NSAttributedString(string: separatorAndTentative, attributes: style.attributes(style.tentative)))
            }
            storage.endEditing()
        }

        private static func endsSentence(_ text: String) -> Bool {
            text.last.map { ".?!。？！".contains($0) } ?? false
        }

        // MARK: - Scrolling

        func scrollToEnd(animated: Bool) {
            (scroll as? TranscriptScrollView)?.scrollToEnd(animated: animated)
        }

        private var isAtBottom: Bool {
            guard let scroll, let text else { return true }
            return scroll.contentView.bounds.maxY >= text.frame.height - 24
        }

        /// Only the user's own scrolling decides whether the view keeps to the newest text.
        @objc private func userScrolled() {
            let atBottom = isAtBottom
            guard atBottom != following.wrappedValue else { return }
            let binding = following
            Task { @MainActor in binding.wrappedValue = atBottom }
        }

        @objc private func textGrew() {
            if following.wrappedValue { scrollToEnd(animated: true) }
        }

        /// Keeps lines to a readable length in wide windows.
        @objc private func frameChanged() {
            guard let scroll, let text else { return }
            let side = max(32, ((scroll.contentSize.width - 720) / 2).rounded())
            if text.textContainerInset.width != side {
                text.textContainerInset = NSSize(width: side, height: 56)
            }
            if following.wrappedValue { scrollToEnd(animated: false) }
        }
    }
}

/// Glides to the newest text, reports wheel and trackpad scrolling, and stops gliding the moment
/// the user takes over.
final class TranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    private var gliding = 0

    func scrollToEnd(animated: Bool) {
        guard let document = documentView else { return }
        let clip = contentView
        let target = NSPoint(x: 0, y: max(0, document.frame.height - clip.bounds.height))
        guard abs(clip.bounds.origin.y - target.y) > 0.5 else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            clip.scroll(to: target)
            reflectScrolledClipView(clip)
            return
        }
        gliding += 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(target)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gliding -= 1
                self.reflectScrolledClipView(clip)
            }
        })
    }

    override func scrollWheel(with event: NSEvent) {
        if gliding > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                contentView.animator().setBoundsOrigin(contentView.bounds.origin)
            }
        }
        super.scrollWheel(with: event)
        onUserScroll?()
    }
}
