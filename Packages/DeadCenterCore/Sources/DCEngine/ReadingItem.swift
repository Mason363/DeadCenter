import Foundation
import DCModel

/// One beat of a reading: a word, an image, or a chapter title card.
public struct ReadingItem: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case word
        case image
        case title
    }

    public var kind: Kind
    /// Display text: the word with its punctuation, the chapter title, or the image caption.
    public var text: String
    /// Extra time beyond one plain word, before pacing strength is applied (punctuation, length, paragraph end).
    public var extra: Double
    /// Whether whitespace separated this item from the previous one in the source (false inside CJK runs).
    public var spaceBefore: Bool
    public var sentence: Int
    public var paragraph: Int
    /// Index into `ReadingStream.chapters`, or -1 before the first chapter.
    public var chapter: Int
    public var image: ImageAsset?
    /// How demanding the item's sentence is to read; 1 is typical prose.
    public var complexity: Double
    /// The display text ends with a hyphen that isn't in the source (a long word split for reading).
    public var addedHyphen: Bool
    /// The innermost bracket or quote this word sits inside, e.g. "(" or "“". The focus view draws
    /// faint marks around such words so an aside stays visible word after word.
    public var enclosure: Character?

    /// The text as it appears in the source, without an added hyphen.
    public var sourceText: String { addedHyphen ? String(text.dropLast()) : text }

    public init(kind: Kind, text: String, extra: Double = 0, spaceBefore: Bool = true,
                sentence: Int, paragraph: Int, chapter: Int, image: ImageAsset? = nil, complexity: Double = 1,
                addedHyphen: Bool = false, enclosure: Character? = nil) {
        self.kind = kind
        self.text = text
        self.extra = extra
        self.spaceBefore = spaceBefore
        self.sentence = sentence
        self.paragraph = paragraph
        self.chapter = chapter
        self.image = image
        self.complexity = complexity
        self.addedHyphen = addedHyphen
        self.enclosure = enclosure
    }
}

public struct Chapter: Sendable, Hashable {
    public var title: String
    /// Index of the chapter's title item in the stream.
    public var itemIndex: Int

    public init(title: String, itemIndex: Int) {
        self.title = title
        self.itemIndex = itemIndex
    }
}

/// Items and chapters produced from one batch of blocks.
public struct TokenBatch: Sendable {
    public var items: [ReadingItem] = []
    public var chapters: [Chapter] = []
    public init() {}
}
