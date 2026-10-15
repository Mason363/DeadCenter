import Foundation
import DCModel

/// Cleans, filters, and batches blocks on their way into the stream.
///
/// Every reader funnels its output through one emitter, which guarantees clean text, drops
/// empty blocks, avoids reading a chapter's title twice, and reports whether anything
/// readable was produced. Confined to the ingesting task.
final class BlockEmitter {
    typealias Continuation = AsyncThrowingStream<IngestEvent, Error>.Continuation

    private let continuation: Continuation
    private let batchSize: Int
    private var buffer: [Block] = []
    private var lastTitle: String?
    private var lastProgress = 0.0
    private var lastChapterKey: String?
    private var chapterEchoBudget = 0
    private var previousWasChapter = false
    /// Text dropped as a repeat of its chapter title, kept in case the document has nothing else.
    private var droppedEchoes: [Block] = []
    private(set) var hasContent = false
    /// Blocks emitted so far, for readers that need to know whether they produced anything.
    private(set) var emittedCount = 0

    init(_ continuation: Continuation, batchSize: Int = 200) {
        self.continuation = continuation
        self.batchSize = batchSize
    }

    func title(_ raw: String?) {
        guard let raw else { return }
        let title = TextNormalizer.truncated(TextNormalizer.clean(raw), limit: 200)
        guard !title.isEmpty, title != lastTitle else { return }
        lastTitle = title
        continuation.yield(.title(title))
    }

    var hasTitle: Bool { lastTitle != nil }

    func emit(_ blocks: [Block]) {
        for block in blocks { emit(block) }
    }

    func emit(_ block: Block) {
        switch block {
        case .chapter(let raw):
            let title = TextNormalizer.clean(raw)
            guard !title.isEmpty else { return }
            let key = TextNormalizer.comparisonKey(title)
            if previousWasChapter, key == lastChapterKey { return }
            lastChapterKey = key
            chapterEchoBudget = 2
            previousWasChapter = true
            append(.chapter(title))

        case .heading(let raw, let level):
            let text = TextNormalizer.clean(raw)
            guard !text.isEmpty else { return }
            if echoesChapter(text, allowContainment: true) {
                droppedEchoes.append(.heading(text, level: min(max(level, 1), 6)))
                return
            }
            chapterEchoBudget = 0
            previousWasChapter = false
            hasContent = true
            append(.heading(text, level: min(max(level, 1), 6)))

        case .paragraph(let raw):
            let text = TextNormalizer.clean(raw)
            guard !text.isEmpty else { return }
            if echoesChapter(text, allowContainment: false) {
                droppedEchoes.append(.paragraph(text))
                return
            }
            chapterEchoBudget = 0
            previousWasChapter = false
            hasContent = true
            append(.paragraph(text))

        case .image(var asset):
            if let caption = asset.caption {
                let cleaned = TextNormalizer.clean(caption)
                asset.caption = cleaned.isEmpty ? nil : cleaned
            }
            previousWasChapter = false
            hasContent = true
            append(.image(asset))
        }
    }

    /// Whether `text`, coming right after a chapter marker, just repeats the chapter's title.
    private func echoesChapter(_ text: String, allowContainment: Bool) -> Bool {
        guard chapterEchoBudget > 0, let chapterKey = lastChapterKey, !chapterKey.isEmpty else { return false }
        let key = TextNormalizer.comparisonKey(text)
        guard !key.isEmpty else { return false }
        let echoes = key == chapterKey || (allowContainment && key.count >= 4 && chapterKey.contains(key))
        if echoes { chapterEchoBudget -= 1 }
        return echoes
    }

    private func append(_ block: Block) {
        buffer.append(block)
        emittedCount += 1
        if buffer.count >= batchSize { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        continuation.yield(.blocks(buffer))
        buffer.removeAll(keepingCapacity: true)
    }

    /// Flushes pending blocks, then reports progress (monotonic, throttled to whole percents).
    func progress(_ value: Double) {
        flush()
        let clamped = min(max(value, 0), 1)
        guard clamped >= lastProgress + 0.01 || (clamped == 1 && lastProgress < 1) else { return }
        lastProgress = clamped
        continuation.yield(.progress(clamped))
    }

    /// Flushes everything; throws `IngestError.empty` if nothing readable was produced.
    func finish() throws {
        if !hasContent, !droppedEchoes.isEmpty {
            // A one-line document whose outline entry repeats it: read the line after all.
            buffer += droppedEchoes
            hasContent = true
        }
        flush()
        guard hasContent else { throw IngestError.empty }
        if lastProgress < 1 { continuation.yield(.progress(1)) }
    }
}
