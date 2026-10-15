import Foundation
import DCModel
import DCEngine

/// A reading whose text arrives over time, such as a live transcript.
/// The reader plays what's there and waits at the end for more.
final class LiveFeed {
    let session: ReaderSession
    private let tokenizer = Tokenizer()
    private(set) var isFinished = false

    fileprivate init(session: ReaderSession) {
        self.session = session
        session.beginLive()
    }

    /// Appends finished text (a sentence or a few). Each call becomes its own paragraph.
    func append(_ text: String) {
        guard !isFinished else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.appendLive(tokenizer.tokenize([.paragraph(trimmed)]))
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        session.endLive()
    }
}

extension ReadingCoordinator {
    /// Opens the reader on a live feed and starts playing as soon as words arrive.
    func startLive(title: String) -> LiveFeed {
        let session = showWaiting(title: title)
        let feed = LiveFeed(session: session)
        session.play()
        return feed
    }
}
