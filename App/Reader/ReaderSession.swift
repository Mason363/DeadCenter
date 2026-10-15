import Foundation
import QuartzCore
import DCModel
import DCEngine
import DCIngest

protocol ReaderSessionDelegate: AnyObject {
    func session(_ session: ReaderSession, didChange change: ReaderSession.Change)
}

/// One document being read: the growing item stream, the position, and the playback clock.
///
/// The view's display link calls `tick(_:)` every frame while playing; the session decides
/// when to advance so words change exactly on frame boundaries without drift.
@Observable
final class ReaderSession {
    enum State: Equatable {
        case loading
        case paused
        case playing
        case finished
        case failed(String)
    }

    enum Change {
        /// The current item changed.
        case item
        /// Play/pause/finish/fail.
        case state
        /// More content arrived, or the title changed.
        case content
    }

    let id: String
    let origin: DocumentOrigin
    private(set) var title: String
    private(set) var stream = ReadingStream()
    private(set) var index = 0
    private(set) var state: State = .loading
    private(set) var isIngesting = false
    private(set) var ingestProgress = 0.0
    /// Set when the user moves through the text while paused, so resuming doesn't rewind.
    private(set) var movedWhilePaused = false
    /// Pasted or typed text that can be edited on the page.
    var isEditable = false
    /// Bumps whenever the stream is replaced rather than appended to.
    private(set) var contentGeneration = 0

    @ObservationIgnored weak var delegate: ReaderSessionDelegate?
    /// Called on every item change while playing and on seeks; used to persist progress.
    @ObservationIgnored var onProgress: ((ReaderSession) -> Void)?

    @ObservationIgnored private var ingestTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResume: Int?
    @ObservationIgnored private var hasExplicitTitle: Bool
    @ObservationIgnored private var nextChange: CFTimeInterval = 0
    @ObservationIgnored private var itemShownAt: CFTimeInterval = 0
    @ObservationIgnored private var currentDuration: Double?
    @ObservationIgnored private var rampRemaining = 0
    @ObservationIgnored private var pausedAt: CFTimeInterval = 0
    @ObservationIgnored private var waitingForContent = false
    @ObservationIgnored private var startPending = false
    private let rampLength = 7

    init(id: String, title: String?, origin: DocumentOrigin) {
        self.id = id
        self.origin = origin
        self.title = title ?? ""
        self.hasExplicitTitle = !(title ?? "").isEmpty
    }

    deinit {
        ingestTask?.cancel()
    }

    // MARK: - Loading

    /// Starts ingesting `input`. Reading can begin as soon as the first words arrive.
    func load(_ input: IngestInput, resumeAt: Int? = nil) {
        ingestTask?.cancel()
        pendingResume = resumeAt.flatMap { $0 > 0 ? $0 : nil }
        isIngesting = true
        let events = Ingestor.ingest(input)
        ingestTask = Task.detached(priority: .userInitiated) { [weak self] in
            let tokenizer = Tokenizer()
            do {
                for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .title(let title):
                        await self?.adoptTitle(title)
                    case .blocks(let blocks):
                        let batch = tokenizer.tokenize(blocks)
                        guard !batch.items.isEmpty else { continue }
                        await self?.append(batch)
                    case .progress(let p):
                        await self?.setProgress(p)
                    }
                }
                await self?.finishIngest(error: nil)
            } catch is CancellationError {
                // Replaced or closed.
            } catch {
                await self?.finishIngest(error: error)
            }
        }
    }

    /// Loads an already-tokenized stream (previews, onboarding).
    func load(_ stream: ReadingStream) {
        ingestTask?.cancel()
        self.stream = stream
        contentGeneration += 1
        isIngesting = false
        index = 0
        state = stream.isEmpty ? .failed("Nothing to read.") : .paused
        delegate?.session(self, didChange: .content)
        delegate?.session(self, didChange: .state)
    }

    func cancelLoading() {
        ingestTask?.cancel()
        ingestTask = nil
        isIngesting = false
    }

    // MARK: - Editing

    /// Replaces the content with edited text, keeping the position at the given word.
    /// Goes through the same cleanup as pasted text (Markdown, TeX, punctuation), so editing on the
    /// page never brings back raw syntax.
    func replaceText(_ text: String, atWord wordIndex: Int) {
        cancelLoading()
        stream = ReadingStream()
        contentGeneration += 1
        index = 0
        startPending = false
        if !hasExplicitTitle { title = "" }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("Nothing to read.")
            delegate?.session(self, didChange: .content)
            delegate?.session(self, didChange: .state)
            return
        }
        state = .loading
        delegate?.session(self, didChange: .content)
        delegate?.session(self, didChange: .state)
        load(.text(text), resumeAt: wordIndex)
    }

    // MARK: - Live

    /// Prepares for text that arrives over time (live transcription) instead of from ingestion.
    func beginLive() {
        ingestTask?.cancel()
        ingestTask = nil
        isIngesting = true
        ingestProgress = 0
    }

    func appendLive(_ batch: TokenBatch) {
        guard !batch.items.isEmpty else { return }
        append(batch)
    }

    func endLive() {
        guard isIngesting else { return }
        finishIngest(error: nil)
    }

    /// Shows a message instead of content ("Nothing to read", load errors).
    func fail(_ message: String) {
        cancelLoading()
        startPending = false
        state = .failed(message)
        delegate?.session(self, didChange: .state)
    }

    /// A placeholder title (a file name) that the document's own title replaces when it arrives.
    func setFallbackTitle(_ fallback: String) {
        guard title.isEmpty else { return }
        title = fallback
    }

    private func adoptTitle(_ title: String) {
        guard !hasExplicitTitle else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        self.title = t
        delegate?.session(self, didChange: .content)
    }

    private func setProgress(_ p: Double) {
        ingestProgress = p
    }

    private func append(_ batch: TokenBatch) {
        stream.append(batch)
        if !hasExplicitTitle, title.isEmpty, let first = batch.chapters.first {
            title = first.title
        }
        if state == .loading {
            if let resume = pendingResume {
                guard resume < stream.count else {
                    delegate?.session(self, didChange: .content)
                    return
                }
                index = stream.sentenceStart(at: resume)
                pendingResume = nil
            }
            state = .paused
            if startPending {
                // Go straight to playing so the paused ribbon never flashes on screen.
                play()
                delegate?.session(self, didChange: .content)
            } else {
                delegate?.session(self, didChange: .content)
                delegate?.session(self, didChange: .state)
            }
            return
        }
        delegate?.session(self, didChange: .content)
        if waitingForContent, state == .playing {
            waitingForContent = false
            advance(at: CACurrentMediaTime())
        }
    }

    private func finishIngest(error: Error?) {
        isIngesting = false
        ingestProgress = 1
        if stream.isEmpty || state == .loading {
            if stream.isEmpty {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error?.localizedDescription ?? "There's no readable text here."
                state = .failed(message)
            } else {
                // Resume point was past the end; start from the top.
                pendingResume = nil
                index = 0
                state = .paused
                if startPending {
                    play()
                    delegate?.session(self, didChange: .content)
                    return
                }
            }
            delegate?.session(self, didChange: .state)
            return
        }
        delegate?.session(self, didChange: .content)
        if waitingForContent, state == .playing {
            waitingForContent = false
            finish()
        }
    }

    // MARK: - Derived

    var currentItem: ReadingItem? {
        stream.items.indices.contains(index) ? stream[index] : nil
    }

    var progress: Double {
        guard stream.count > 1 else { return state == .finished ? 1 : 0 }
        if isIngesting, ingestProgress > 0 {
            // Estimate against the projected total while the document is still streaming in.
            let projected = Double(stream.count) / max(ingestProgress, 0.01)
            return min(Double(index) / projected, 1)
        }
        return Double(index) / Double(stream.count - 1)
    }

    var pacer: Pacer {
        let prefs = Preferences.shared
        return Pacer(wpm: Double(prefs.wpm), pacingStrength: prefs.pacing.strength,
                     imageSeconds: prefs.showImages ? prefs.imageDuration : 0, meanExtra: stream.meanExtra,
                     adaptive: prefs.adaptiveSpeed, meanComplexity: stream.meanComplexity)
    }

    var remainingSeconds: Double {
        stream.remainingSeconds(from: index, pacer: pacer)
    }

    /// 0…1 through the current timed beat (image countdown), or nil when untimed.
    func beatProgress(at now: CFTimeInterval) -> Double? {
        guard state == .playing, let d = currentDuration, d > 0 else { return nil }
        return min(max((now - itemShownAt) / d, 0), 1)
    }

    var isHoldingImage: Bool {
        state == .playing && currentItem?.kind == .image && currentDuration == nil
    }

    // MARK: - Playback

    /// Starts playing, or arranges to start as soon as content arrives.
    func play() {
        switch state {
        case .loading:
            startPending = true
            return
        case .failed, .playing:
            return
        case .finished:
            index = 0
        case .paused:
            let now = CACurrentMediaTime()
            if Preferences.shared.resumeAtSentence, !movedWhilePaused, pausedAt > 0, now - pausedAt > 1.2,
               currentItem?.kind == .word {
                let start = stream.sentenceStart(at: index)
                index = index - start <= 14 ? start : max(index - 4, start)
            }
        }
        startPending = false
        movedWhilePaused = false
        state = .playing
        rampRemaining = Preferences.shared.easeIn ? rampLength : 0
        if !Preferences.shared.showImages { skipImages(forward: true) }
        delegate?.session(self, didChange: .state)
        delegate?.session(self, didChange: .item)
        show(at: CACurrentMediaTime())
    }

    func pause() {
        startPending = false
        guard state == .playing else { return }
        state = .paused
        pausedAt = CACurrentMediaTime()
        waitingForContent = false
        movedWhilePaused = false
        delegate?.session(self, didChange: .state)
        onProgress?(self)
    }

    func togglePlayback() {
        if state == .playing { pause() } else { play() }
    }

    /// Advances when the current item's time is up. Call once per display frame.
    func tick(_ now: CFTimeInterval) {
        guard state == .playing, !waitingForContent else { return }
        guard now >= nextChange - 0.004 else { return }
        advance(at: now)
    }

    /// Called when a held image should move on (→ or Space while an image waits).
    func continueFromHold() {
        guard isHoldingImage else { return }
        advance(at: CACurrentMediaTime())
    }

    private func show(at now: CFTimeInterval) {
        itemShownAt = now
        currentDuration = duration(at: index)
        if let d = currentDuration {
            nextChange = now + d
        } else {
            nextChange = .infinity
        }
    }

    private func advance(at now: CFTimeInterval) {
        var next = index + 1
        if !Preferences.shared.showImages {
            while next < stream.count, stream[next].kind == .image { next += 1 }
        }
        guard next < stream.count else {
            if isIngesting {
                waitingForContent = true
            } else {
                finish()
            }
            return
        }
        index = next
        if rampRemaining > 0, stream[index].kind == .word { rampRemaining -= 1 }
        // If a frame was missed, don't burst through words to catch up.
        let scheduled = nextChange.isFinite && nextChange > now - 0.05 ? nextChange : now
        show(at: scheduled)
        delegate?.session(self, didChange: .item)
        onProgress?(self)
    }

    private func duration(at i: Int) -> Double? {
        guard stream.items.indices.contains(i), let base = pacer.duration(of: stream[i]) else { return nil }
        guard stream[i].kind == .word, rampRemaining > 0 else { return base }
        return base * (1 + 0.85 * Double(rampRemaining) / Double(rampLength))
    }

    private func finish() {
        state = .finished
        waitingForContent = false
        delegate?.session(self, didChange: .state)
        onProgress?(self)
    }

    private func skipImages(forward: Bool) {
        while let item = currentItem, item.kind == .image {
            let next = index + (forward ? 1 : -1)
            guard stream.items.indices.contains(next) else { break }
            index = next
        }
    }

    // MARK: - Navigation

    /// Moves to `target`. While playing, playback continues from there with a short ease-in.
    func seek(to target: Int) {
        guard !stream.isEmpty else { return }
        let clamped = min(max(target, 0), stream.count - 1)
        if state == .finished { state = .paused; delegate?.session(self, didChange: .state) }
        guard clamped != index else { return }
        index = clamped
        if state == .playing {
            rampRemaining = Preferences.shared.easeIn ? 3 : 0
            show(at: CACurrentMediaTime())
        } else {
            movedWhilePaused = true
        }
        delegate?.session(self, didChange: .item)
        onProgress?(self)
    }

    func step(_ delta: Int) {
        seek(to: index + delta)
    }

    func jumpSentence(forward: Bool) {
        if forward {
            if let next = stream.nextSentenceStart(from: index) { seek(to: next) }
        } else {
            seek(to: stream.previousSentenceStart(from: index))
        }
    }

    func jumpParagraph(forward: Bool) {
        if forward {
            if let next = stream.nextParagraphStart(from: index) { seek(to: next) }
        } else {
            seek(to: stream.previousParagraphStart(from: index))
        }
    }

    func jumpChapter(forward: Bool) {
        let target = forward ? stream.nextChapterStart(from: index) : stream.previousChapterStart(from: index)
        if let target { seek(to: target) }
    }

    func seekToStart() { seek(to: 0) }
    func seekToEnd() { seek(to: stream.count - 1) }

    /// Re-derives the current item's timing after a speed or pacing change.
    func timingChanged() {
        guard state == .playing, currentDuration != nil else { return }
        let elapsed = CACurrentMediaTime() - itemShownAt
        currentDuration = duration(at: index)
        if let d = currentDuration { nextChange = itemShownAt + max(d, elapsed) }
    }
}
