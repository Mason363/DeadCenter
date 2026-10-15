import Foundation
import Observation

/// A stretch of transcribed speech. Times are seconds from the start of the recording or file.
nonisolated struct TranscriptSegment: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// Set when the segment is added: a long pause or a long paragraph starts a new one.
    var startsParagraph = false
}

/// The transcript in the window: confirmed segments plus a tentative tail that may still change.
@Observable
final class Transcript {
    private(set) var segments: [TranscriptSegment] = []
    private(set) var tentative = ""
    /// Changes whenever the transcript is replaced rather than extended.
    private(set) var generation = 0
    private(set) var title = "Transcript"
    private var paragraphLength = 0

    var isEmpty: Bool { segments.isEmpty && tentative.isEmpty }
    var duration: TimeInterval { segments.last?.end ?? 0 }

    func reset(title: String) {
        segments = []
        tentative = ""
        paragraphLength = 0
        self.title = title
        generation += 1
    }

    /// Adds confirmed segments, deciding paragraph breaks as they arrive so every view and export agrees.
    func append(_ new: [TranscriptSegment]) {
        guard !new.isEmpty else { return }
        var added = new
        for i in added.indices {
            let previous = i > 0 ? added[i - 1] : segments.last
            if let previous {
                let pause = added[i].start - previous.end
                let sentenceEnded = previous.text.last.map { ".?!。？！".contains($0) } ?? false
                added[i].startsParagraph = pause > 2.5 || (paragraphLength > 600 && sentenceEnded)
            } else {
                added[i].startsParagraph = true
            }
            if added[i].startsParagraph { paragraphLength = 0 }
            paragraphLength += added[i].text.count
        }
        segments.append(contentsOf: added)
    }

    func setTentative(_ text: String) {
        if text != tentative { tentative = text }
    }

    /// Confirmed segments grouped into paragraphs.
    var paragraphs: [[TranscriptSegment]] {
        var result: [[TranscriptSegment]] = []
        for segment in segments {
            if segment.startsParagraph || result.isEmpty {
                result.append([segment])
            } else {
                result[result.count - 1].append(segment)
            }
        }
        return result
    }

    // MARK: - Export

    var plainText: String {
        paragraphs.map { Self.join($0.map(\.text)) }.joined(separator: "\n\n")
    }

    var markdown: String {
        let body = paragraphs.map { paragraph in
            "**\(Self.clock(paragraph[0].start))** \(Self.join(paragraph.map(\.text)))"
        }
        return (["# \(title)"] + body).joined(separator: "\n\n") + "\n"
    }

    var subRip: String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(Self.srtTime(segment.start)) --> \(Self.srtTime(max(segment.end, segment.start + 0.5)))\n\(segment.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Formatting

    /// Joins pieces of speech, without spaces between scripts that don't use them.
    nonisolated static func join(_ pieces: [String]) -> String {
        var result = ""
        for piece in pieces where !piece.isEmpty {
            result += separator(after: result, before: piece) + piece
        }
        return result
    }

    nonisolated static func separator(after previous: String, before next: String) -> String {
        guard let last = previous.last, let first = next.first else { return "" }
        return last.isUnspaced || first.isUnspaced || last.isNewline ? "" : " "
    }

    /// `4:05` or `1:02:09`.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func srtTime(_ seconds: TimeInterval) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}

private extension Character {
    /// Han, kana and full-width punctuation: written without spaces between words.
    nonisolated var isUnspaced: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }
}
