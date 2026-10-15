import Foundation

/// A document as a flat sequence of reading items, growing as ingestion streams in.
public struct ReadingStream: Sendable {
    public private(set) var items: [ReadingItem] = []
    public private(set) var chapters: [Chapter] = []
    public private(set) var wordCount = 0
    private var extraSum: Double = 0
    private var complexitySum: Double = 0

    public init() {}

    public init(batch: TokenBatch) {
        append(batch)
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// Average pause weight per word, used to normalize pacing. A typical value until enough text is in.
    public var meanExtra: Double {
        wordCount >= 40 ? extraSum / Double(wordCount) : 0.4
    }

    /// Average sentence complexity per word; 1 until enough text is in.
    public var meanComplexity: Double {
        wordCount >= 40 ? complexitySum / Double(wordCount) : 1
    }

    public mutating func append(_ batch: TokenBatch) {
        items.append(contentsOf: batch.items)
        chapters.append(contentsOf: batch.chapters)
        for item in batch.items where item.kind == .word {
            wordCount += 1
            extraSum += item.extra
            complexitySum += item.complexity
        }
    }

    /// Replaces the whole stream (after editing the text).
    public mutating func reset(with batch: TokenBatch) {
        self = ReadingStream(batch: batch)
    }

    public subscript(i: Int) -> ReadingItem { items[i] }

    // MARK: - Sentences

    public func sentenceStart(at i: Int) -> Int {
        guard items.indices.contains(i) else { return 0 }
        let s = items[i].sentence
        var j = i
        while j > 0, items[j - 1].sentence == s { j -= 1 }
        return j
    }

    /// "Back": the start of the current sentence, or of the previous one if we're already near the start.
    public func previousSentenceStart(from i: Int) -> Int {
        let start = sentenceStart(at: i)
        if i - start > 1 || start == 0 { return start }
        return sentenceStart(at: start - 1)
    }

    public func nextSentenceStart(from i: Int) -> Int? {
        guard items.indices.contains(i) else { return nil }
        let s = items[i].sentence
        var j = i + 1
        while j < items.count, items[j].sentence == s { j += 1 }
        return j < items.count ? j : nil
    }

    // MARK: - Paragraphs

    public func paragraphStart(at i: Int) -> Int {
        guard items.indices.contains(i) else { return 0 }
        let p = items[i].paragraph
        var j = i
        while j > 0, items[j - 1].paragraph == p { j -= 1 }
        return j
    }

    public func previousParagraphStart(from i: Int) -> Int {
        let start = paragraphStart(at: i)
        if i - start > 1 || start == 0 { return start }
        return paragraphStart(at: start - 1)
    }

    public func nextParagraphStart(from i: Int) -> Int? {
        guard items.indices.contains(i) else { return nil }
        let p = items[i].paragraph
        var j = i + 1
        while j < items.count, items[j].paragraph == p { j += 1 }
        return j < items.count ? j : nil
    }

    // MARK: - Chapters

    public func chapter(at i: Int) -> Chapter? {
        guard items.indices.contains(i) else { return nil }
        let c = items[i].chapter
        return chapters.indices.contains(c) ? chapters[c] : nil
    }

    public func previousChapterStart(from i: Int) -> Int? {
        guard items.indices.contains(i) else { return nil }
        let c = items[i].chapter
        guard chapters.indices.contains(c) else { return chapters.isEmpty ? nil : 0 }
        let start = chapters[c].itemIndex
        if i - start > 3 || c == 0 { return start }
        return chapters[c - 1].itemIndex
    }

    public func nextChapterStart(from i: Int) -> Int? {
        guard items.indices.contains(i) else { return nil }
        let next = items[i].chapter + 1
        return chapters.indices.contains(next) ? chapters[next].itemIndex : nil
    }

    // MARK: - Time

    /// Seconds left from item `i` to the end at the given pacing. Held images count as their default 10 s.
    public func remainingSeconds(from i: Int, pacer: Pacer) -> Double {
        guard items.indices.contains(i) else { return 0 }
        var total = 0.0
        for item in items[i...] {
            total += pacer.duration(of: item) ?? 10
        }
        return total
    }
}
