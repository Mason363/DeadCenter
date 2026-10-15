import Testing
import Foundation
import DCModel
@testable import DCEngine

@Suite struct PivotTests {
    @Test(arguments: [
        ("a", 0), ("an", 1), ("read", 1), ("reading", 2), ("beautiful", 2),
        ("comprehension", 3), ("internationally", 4),
    ])
    func optimal(word: String, expected: Int) {
        #expect(Pivot.index(in: word, rule: .optimal) == expected)
    }

    @Test func ignoresPunctuation() {
        #expect(Pivot.index(in: "“Hello,", rule: .optimal) == 2)
        #expect(Pivot.index(in: "(reading)", rule: .optimal) == 3)
    }

    @Test func middle() {
        #expect(Pivot.index(in: "reading", rule: .middle) == 3)
        #expect(Pivot.index(in: "speed", rule: .middle) == 2)
        #expect(Pivot.index(in: "comprehension", rule: .middle) == 6)
    }

    @Test func noLetters() {
        #expect(Pivot.index(in: "—", rule: .optimal) == 0)
        #expect(Pivot.index(in: "", rule: .optimal) == 0)
    }
}

@Suite struct TokenizerTests {
    func words(_ blocks: [Block]) -> [String] {
        Tokenizer().tokenize(blocks).items.map(\.text)
    }

    @Test func keepsPunctuationAndCountsSentences() {
        let batch = Tokenizer().tokenize([.paragraph("Hello there, world. How are you?\nFine.")])
        #expect(batch.items.map(\.text) == ["Hello", "there,", "world.", "How", "are", "you?", "Fine."])
        #expect(Set(batch.items.map(\.sentence)).count == 3)
        #expect(batch.items[1].extra > batch.items[0].extra)
        #expect(batch.items[2].extra > batch.items[1].extra)
        // Paragraph end gets the longest pause.
        #expect(batch.items.last!.extra > batch.items[2].extra)
    }

    @Test func abbreviationsDontEndSentencePause() {
        let items = Tokenizer().tokenize([.paragraph("Ask Dr. Smith today")]).items
        #expect(items[1].extra < 0.5)
    }

    @Test func splitsLongWords() {
        let pieces = words([.paragraph("incomprehensibilities")])
        #expect(pieces.count >= 2)
        #expect(pieces.dropLast().allSatisfy { $0.hasSuffix("-") })
        #expect(pieces.joined().replacingOccurrences(of: "-", with: "") == "incomprehensibilities")
        #expect(pieces.allSatisfy { $0.count <= Tokenizer.longWordThreshold })
    }

    @Test func splitsAtExistingHyphens() {
        let pieces = words([.paragraph("state-of-the-art-technology")])
        #expect(pieces.joined() == "state-of-the-art-technology")
    }

    @Test func segmentsChinese() {
        let items = Tokenizer().tokenize([.paragraph("我们今天去图书馆看书。")]).items
        #expect(items.count >= 2)
        #expect(items.map(\.text).joined() == "我们今天去图书馆看书。")
        #expect(items.dropFirst().allSatisfy { !$0.spaceBefore })
        #expect(items.last!.text.hasSuffix("。"))
    }

    @Test func chaptersAndImages() {
        let image = ImageAsset(source: .url(URL(string: "https://example.com/a.png")!))
        let t = Tokenizer()
        let first = t.tokenize([.chapter("One"), .paragraph("Alpha beta."), .image(image)])
        let second = t.tokenize([.chapter("Two"), .paragraph("Gamma.")])
        var stream = ReadingStream(batch: first)
        stream.append(second)
        #expect(stream.chapters.map(\.title) == ["One", "Two"])
        #expect(stream.chapters[1].itemIndex == 4)
        #expect(stream[3].kind == .image)
        #expect(stream[5].chapter == 1)
        #expect(stream.nextChapterStart(from: 1) == 4)
    }

    @Test func navigation() {
        let stream = ReadingStream(batch: Tokenizer().tokenize([
            .paragraph("One two three. Four five six."),
            .paragraph("Seven eight."),
        ]))
        #expect(stream.nextSentenceStart(from: 0) == 3)
        #expect(stream.previousSentenceStart(from: 5) == 3)
        #expect(stream.previousSentenceStart(from: 3) == 0)
        #expect(stream.nextParagraphStart(from: 1) == 6)
        #expect(stream.paragraphStart(at: 7) == 6)
    }

    @Test func neverFasterThanChosenSpeed() {
        let stream = ReadingStream(batch: Tokenizer().tokenize([.paragraph(
            String(repeating: "The quick brown fox jumps over the lazy dog, again and again. ", count: 20))]))
        for strength in [0.0, 1.0, 1.6] {
            let pacer = Pacer(wpm: 300, pacingStrength: strength, imageSeconds: 10, meanExtra: stream.meanExtra)
            for item in stream.items {
                #expect(pacer.duration(of: item)! >= 0.2 - 1e-9)
            }
        }
        let even = Pacer(wpm: 300, pacingStrength: 0, imageSeconds: 10, meanExtra: stream.meanExtra)
        let total = stream.remainingSeconds(from: 0, pacer: even)
        #expect(abs(total - Double(stream.wordCount) / 300 * 60) < 1e-6)
    }
}

@Suite struct AdaptiveTests {
    @Test func denseTextReadsSlowerThanSimpleText() {
        let simple = ReadingStream(batch: Tokenizer().tokenize([.paragraph(
            String(repeating: "The cat sat on the mat and it was a good day for a nap. ", count: 10))]))
        let dense = ReadingStream(batch: Tokenizer().tokenize([.paragraph(
            String(repeating: "Electrochemical characterization demonstrates heterogeneous nucleation mechanisms. ", count: 10))]))
        #expect(dense.meanComplexity > 1.1)
        #expect(simple.meanComplexity < 0.95)
        func pacer(_ s: ReadingStream) -> Pacer {
            Pacer(wpm: 300, pacingStrength: 1, imageSeconds: 10, meanExtra: s.meanExtra,
                  adaptive: true, meanComplexity: s.meanComplexity)
        }
        #expect(pacer(dense).effectiveWPM < 300)
        // Adaptive speed only ever slows down.
        #expect(pacer(simple).effectiveWPM == 300)
        for item in simple.items {
            #expect(pacer(simple).duration(of: item)! >= 0.2 - 1e-9)
        }
    }

    @Test func offMeansExactSpeed() {
        let stream = ReadingStream(batch: Tokenizer().tokenize([.paragraph(
            String(repeating: "Electrochemical characterization demonstrates heterogeneous nucleation. ", count: 10))]))
        let pacer = Pacer(wpm: 300, pacingStrength: 1, imageSeconds: 10, meanExtra: stream.meanExtra,
                          adaptive: false, meanComplexity: stream.meanComplexity)
        #expect(pacer.effectiveWPM == 300)
    }
}

@Suite struct PunctuationTests {
    func items(_ text: String) -> [ReadingItem] {
        Tokenizer().tokenize([.paragraph(text)]).items
    }

    @Test func loneDashesBecomePauses() {
        let words = items("It was late — very late – and dark - truly dark.")
        #expect(words.map(\.text) == ["It", "was", "late\u{2009}—", "very", "late\u{2009}—", "and", "dark\u{2009}—", "truly", "dark."])
        #expect(words[2].extra > words[1].extra)
    }

    @Test func joinedEmDashesSplit() {
        #expect(items("this—that—the other").map(\.text) == ["this—", "that—", "the", "other"])
        #expect(items("from 1990–2000 only").map(\.text) == ["from", "1990–2000", "only"])
        #expect(items("wait--what").map(\.text) == ["wait—", "what"])
    }

    @Test func separatorsAndCitationsDisappear() {
        #expect(items("Before ------ after ===== end").map(\.text) == ["Before", "after", "end"])
        #expect(items("Proven fact.[12] More[citation needed] text[a].").map(\.text) == ["Proven", "fact.", "More", "text."])
    }

    @Test func longHyphenatedWordsSplitAtHyphens() {
        let parts = items("an anti-inflammatory-drug-resistant strain").map(\.text)
        #expect(parts == ["an", "anti-", "inflammatory-", "drug-resistant", "strain"])
        // Short compounds stay whole.
        #expect(items("a state-of-the-art tool").map(\.text) == ["a", "state-of-the-art", "tool"])
    }

    @Test func linksAreCondensed() {
        #expect(items("See https://www.example.com/a/very/long/path?x=1, then go.").map(\.text)
                == ["See", "example.com/…,", "then", "go."])
    }

    @Test func enclosuresAreTracked() {
        let words = items("He said (quite loudly, in fact) that “we are done.” Then [maybe] left.")
        let texts = words.map(\.text)
        let encl = words.map(\.enclosure)
        #expect(texts == ["He", "said", "(quite", "loudly,", "in", "fact)", "that", "“we", "are", "done.”", "Then", "[maybe]", "left."])
        #expect(encl == [nil, nil, "(", "(", "(", "(", nil, "“", "“", "“", nil, "[", nil])
        #expect(words.map(\.focusText) == ["He", "said", "quite", "loudly,", "in", "fact", "that", "we", "are", "done.", "Then", "maybe", "left."])
        // Pauses mark the start and end of an aside.
        #expect(words[5].extra > words[4].extra)
    }

    @Test func straightQuotesOpenAndClose() {
        let words = items("She said \"hello there,\" and left.")
        #expect(words.map(\.enclosure) == [nil, nil, "\"", "\"", nil, nil])
        #expect(words.map(\.focusText)[2...3] == ["hello", "there,"])
    }

    @Test func apostrophesAreNotQuotes() {
        let words = items("The students’ work isn’t done (it’s close).")
        #expect(words.map(\.focusText) == ["The", "students’", "work", "isn’t", "done", "it’s", "close."])
    }

    @Test func bareWordsDropBracketsQuotesAndDashes() {
        let words = items("He said (quite loudly) that “we’re ‘done.’” It was late — very late; this—that 1990–2000 well-known.")
        #expect(words.map(\.bareText) == ["He", "said", "quite", "loudly", "that", "we’re", "done.", "It", "was", "late",
                                           "very", "late;", "this", "that", "1990–2000", "well-known."])
        #expect(TextShaping.bareWord("[12],") == "12,")
        #expect(TextShaping.bareWord("—") == "—")
        #expect(TextShaping.bareWord("…") == "…")
        #expect(TextShaping.bareWord("Constan-") == "Constan-")
        #expect(TextShaping.bareWord("«Bonjour»") == "Bonjour")
        #expect(TextShaping.bareWord("(🎉)") == "🎉")
    }

    @Test func spacedBracketsAttach() {
        let words = items("a ( spaced ) aside")
        #expect(words.map(\.text) == ["a", "spaced", "aside"])
        #expect(words.map(\.enclosure) == [nil, "(", nil])
    }
}

@Suite struct UnicodeSafetyTests {
    @Test(arguments: ["🇯🇵日本", "🇨🇳中国队夺冠", "🇯🇵ひらがな", "👍🏽日本", "👋🏻こんにちは", "🇯🇵🇺🇸日本", "✌🏿中文", "👍🏽?ไทย"])
    func emojiBeforeSpacelessScripts(text: String) {
        let items = Tokenizer().tokenize([.paragraph(text)]).items
        // Nothing lost, nothing split inside a character, no replacement characters.
        #expect(items.map(\.text).joined() == text)
        #expect(!items.contains { $0.text.contains("\u{FFFD}") })
    }

    @Test func emojiWordsAreKept() {
        let words = Tokenizer().tokenize([.paragraph("Family 👨‍👩‍👧‍👦 trip 🇯🇵 and 😀😀😀 done & dusted.")]).items.map(\.text)
        #expect(words == ["Family", "👨‍👩‍👧‍👦", "trip", "🇯🇵", "and", "😀😀😀", "done", "&", "dusted."])
    }

    @Test func hyphenationNeverSplitsEmoji() {
        let text = "abcdefghijklmn👨‍👩‍👧‍👦xyz"
        let items = Tokenizer().tokenize([.paragraph(text)]).items
        #expect(!items.contains { $0.text.contains("\u{FFFD}") })
        #expect(items.map(\.sourceText).joined() == text)
    }
}
