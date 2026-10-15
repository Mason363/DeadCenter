import Foundation
import WhisperKit

/// What the live transcriber reports after each pass.
nonisolated struct LiveUpdate: Sendable {
    var confirmed: [TranscriptSegment]
    var tentative: String
}

/// Streams audio into Whisper. About once a second it re-transcribes a window of recent audio;
/// words are confirmed once two passes agree on them, or when the speaker pauses. The window is
/// trimmed at the end of confirmed sentences, so it stays a few seconds long: passes stay quick and
/// memory stays flat however long the session runs.
nonisolated struct LiveTranscriber {
    let service: WhisperService
    var options: DecodingOptions
    /// Seconds already on the clock, so a resumed session keeps counting.
    var startOffset: TimeInterval = 0

    private static let rate = Double(AudioMixer.sampleRate)
    private static let step = Int(1.0 * rate)
    private static let pause = Int(0.8 * rate)

    /// Runs until the mixer is finished and drained, then confirms whatever is left.
    @concurrent
    func run(mixer: AudioMixer, update: @escaping @MainActor @Sendable (LiveUpdate) -> Void) async throws {
        let rate = Self.rate
        var options = self.options
        options.wordTimestamps = true
        var window: [Float] = []
        var windowStart = 0
        var total = 0
        var lastPass = 0
        var speech = SpeechDetector()
        var pending: [Word] = []
        var committed = CommittedWords(end: startOffset)
        var finished = false

        func drop(_ count: Int) {
            let count = min(window.count, max(0, count))
            window.removeFirst(count)
            windowStart += count
        }

        while !finished {
            try Task.checkCancellation()
            let (fresh, done) = mixer.drain()
            finished = done
            window.append(contentsOf: fresh)
            speech.feed(fresh)
            total += fresh.count

            let unheard = total - lastPass
            let paused = total - speech.lastVoice >= Self.pause
            guard finished || unheard >= Self.step || (paused && !pending.isEmpty && unheard > 0) else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            lastPass = total

            guard speech.lastVoice > windowStart else {
                // Nothing said: keep a short lead-in so the next word's onset survives.
                drop(window.count - Int(0.5 * rate))
                if !pending.isEmpty {
                    pending = []
                    await update(LiveUpdate(confirmed: [], tentative: ""))
                }
                continue
            }

            let results = try await service.transcribe(window, options: options)
            let offset = startOffset + Double(windowStart) / rate
            let seconds = Double(window.count) / rate
            let words = results.flatMap(\.segments).flatMap { Word.all(in: $0, offset: offset) }
            let new = committed.unseen(in: words)

            var count = 0
            if finished || paused {
                count = new.count
            } else {
                // The newest word waits for one more behind it, so Whisper has context for its punctuation.
                while count < new.count - 1, count < pending.count, new[count].matches(pending[count]) {
                    count += 1
                }
                // Passes that keep disagreeing mustn't let the window grow toward Whisper's 30 s limit.
                if seconds >= 20 {
                    count = max(count, new.prefix { $0.end <= offset + seconds - 5 }.count)
                }
            }
            let confirmed = Array(new.prefix(count))
            pending = Array(new.dropFirst(count))
            committed.add(confirmed)

            if !confirmed.isEmpty, options.language == nil, let language = results.first?.language {
                // Once speech has been confirmed, stop re-detecting the language on every pass.
                options.language = language
                options.detectLanguage = false
            }

            // Trim with a little overlap: words heard twice are matched up and skipped, lost ones are gone.
            if pending.isEmpty && (paused || finished) {
                drop(window.count - Int(0.2 * rate))
            } else if seconds >= 8, let cut = Word.sentenceBoundary(in: words, before: committed.end) {
                drop(Int(((cut - 0.2 - offset) * rate).rounded()))
            } else if seconds >= 20 {
                drop(Int(((committed.end - 0.2 - offset) * rate).rounded()))
            }

            await update(LiveUpdate(confirmed: Word.sentences(from: confirmed),
                                    tentative: pending.map(\.text).joined().trimmingCharacters(in: .whitespaces)))
        }
    }
}

/// The tail of what has been confirmed, to tell new words from ones already said.
nonisolated private struct CommittedWords {
    var end: TimeInterval
    private var tail: [Word] = []

    init(end: TimeInterval) {
        self.end = end
    }

    mutating func add(_ words: [Word]) {
        guard let last = words.last else { return }
        end = max(end, last.end)
        tail = Array((tail + words).suffix(8))
    }

    /// The words in a new pass that come after what's already confirmed. Lines the confirmed tail up
    /// with the new text where it can, since word timings drift by a few tenths of a second.
    func unseen(in words: [Word]) -> [Word] {
        for n in stride(from: min(5, tail.count), through: min(2, tail.count), by: -1) where n > 0 {
            let needle = tail.suffix(n)
            for i in stride(from: words.count - n, through: 0, by: -1) where words[i + n - 1].middle <= end + 0.5 {
                if zip(needle, words[i..<i + n]).allSatisfy({ $0.matches($1) }) {
                    return Array(words[(i + n)...])
                }
            }
        }
        return Array(words.drop { $0.middle <= end })
    }
}

/// A word with absolute times. Whisper's word text carries its own leading space where the language uses one.
nonisolated private struct Word {
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    static func all(in segment: TranscriptionSegment, offset: TimeInterval) -> [Word] {
        guard let spoken = segment.spokenText else { return [] }
        guard let words = segment.words, !words.isEmpty else {
            // No word timings for this segment: treat it as one long word.
            return [Word(text: " " + spoken, start: offset + Double(segment.start), end: offset + Double(segment.end))]
        }
        return words.map { Word(text: $0.word, start: offset + Double($0.start), end: offset + Double($0.end)) }
    }

    var middle: TimeInterval { (start + end) / 2 }

    /// Same word, ignoring case and punctuation.
    func matches(_ other: Word) -> Bool {
        Self.normalized(text) == Self.normalized(other.text)
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Where the last finished sentence that ends by `limit` stops: a clean place to trim audio.
    static func sentenceBoundary(in words: [Word], before limit: TimeInterval) -> TimeInterval? {
        guard let index = words.lastIndex(where: { $0.end <= limit + 0.05 && $0.endsSentence }) else { return nil }
        let next = words.index(after: index)
        return next < words.endIndex ? min(words[index].end, words[next].start) : words[index].end
    }

    var endsSentence: Bool {
        text.trimmingCharacters(in: .whitespaces).last.map { ".?!。？！".contains($0) } ?? false
    }

    /// Confirmed words as transcript segments, one per sentence (or part of one).
    static func sentences(from words: [Word]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [Word] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                segments.append(TranscriptSegment(start: first.start, end: last.end, text: text))
            }
            current = []
        }
        for word in words {
            current.append(word)
            if word.endsSentence { close() }
        }
        close()
        return segments
    }
}

/// Voice activity over 100 ms frames, using WhisperKit's energy measures against a rolling noise floor.
nonisolated struct SpeechDetector {
    /// Sample index where the latest voiced frame ends.
    private(set) var lastVoice = 0
    private var carry: [Float] = []
    private var position = 0
    private var recent: [Float] = []
    private let frame = AudioMixer.sampleRate / 10

    mutating func feed(_ samples: [Float]) {
        carry.append(contentsOf: samples)
        var offset = 0
        while carry.count - offset >= frame {
            let chunk = Array(carry[offset..<offset + frame])
            let energy = AudioProcessor.calculateAverageEnergy(of: chunk)
            recent.append(energy)
            if recent.count > 50 { recent.removeFirst() }
            let floor = max(recent.min() ?? 0, 0.001)
            if energy > 0.002, AudioProcessor.calculateRelativeEnergy(of: chunk, relativeTo: floor) > 0.2 {
                lastVoice = position + offset + frame
            }
            offset += frame
        }
        carry.removeFirst(offset)
        position += offset
    }
}
