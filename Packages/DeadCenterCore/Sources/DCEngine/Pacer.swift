import Foundation

/// Turns items into on-screen durations.
///
/// The chosen speed is a ceiling: no word is ever shown for less than `60 / wpm` seconds.
/// Pacing (punctuation, paragraph ends, long words) and adaptive speed only ever add time.
public struct Pacer: Sendable, Equatable {
    public var wpm: Double
    /// 0 = every word gets the same time; 1 = natural; higher = more pronounced pauses.
    public var pacingStrength: Double
    /// Seconds an image stays up; 0 holds it until the user continues.
    public var imageSeconds: Double
    /// The stream's average `extra` per word (`ReadingStream.meanExtra`). Used for time estimates only.
    public var meanExtra: Double
    /// Adapt to the text by slowing down for dense passages and harder documents (never speeding up).
    public var adaptive: Bool
    /// The stream's average complexity (`ReadingStream.meanComplexity`).
    public var meanComplexity: Double

    public init(wpm: Double, pacingStrength: Double, imageSeconds: Double, meanExtra: Double,
                adaptive: Bool = false, meanComplexity: Double = 1) {
        self.wpm = wpm
        self.pacingStrength = pacingStrength
        self.imageSeconds = imageSeconds
        self.meanExtra = meanExtra
        self.adaptive = adaptive
        self.meanComplexity = meanComplexity
    }

    public var baseInterval: Double { 60 / max(wpm, 1) }

    /// How much the whole document is slowed down for its difficulty (≥ 1).
    public var documentFactor: Double {
        adaptive ? min(max(meanComplexity, 1), 1.22) : 1
    }

    /// Words per minute actually delivered after adapting to the document.
    public var effectiveWPM: Double { wpm / documentFactor }

    /// Seconds the item stays on screen, or nil to hold until the user continues.
    public func duration(of item: ReadingItem) -> Double? {
        switch item.kind {
        case .word:
            var seconds = baseInterval * (1 + max(item.extra, 0) * pacingStrength)
            if adaptive {
                let local = min(max(item.complexity / max(meanComplexity, 0.1), 1), 1.18)
                seconds *= local * documentFactor
            }
            return seconds
        case .title:
            return min(max(baseInterval * 7, 1.1), 2.0)
        case .image:
            return imageSeconds > 0 ? imageSeconds : nil
        }
    }
}
