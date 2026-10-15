import Foundation
import Testing
import DCModel
@testable import DCIngest

@Suite("Text cleanup")
struct TextNormalizerTests {
    @Test("Cleans invisible characters, ligatures, whitespace, and normalizes to NFC")
    func clean() {
        #expect(TextNormalizer.clean("  ﬁne  ﬂow\u{00A0}and\u{200B} co\u{00AD}operate\n\tnow ") == "fine flow and cooperate now")
        #expect(TextNormalizer.clean("cafe\u{0301}") == "café")
        #expect(TextNormalizer.clean("smart \u{93}quotes\u{94}") == "smart “quotes”")
        #expect(TextNormalizer.clean("a\u{2028}b\u{2029}c") == "a b c")
        #expect(TextNormalizer.clean("\u{FEFF}BOM") == "BOM")
    }

    @Test("Joins wrapped lines, undoing hyphenation")
    func join() {
        #expect(TextNormalizer.join("an exam-", "ple") == "an example")
        #expect(TextNormalizer.join("a well-", "known fact", compounds: ["well-known"]) == "a well-known fact")
        #expect(TextNormalizer.join("Jean-", "Paul") == "Jean-Paul")
        #expect(TextNormalizer.join("soft\u{AD}", "ware") == "software")
        #expect(TextNormalizer.join("一二三", "四五") == "一二三四五")
        #expect(TextNormalizer.join("wait—", "what") == "wait—what")
        #expect(TextNormalizer.join("plain ", " words") == "plain words")
    }

    @Test("Strips bullets but keeps dialogue dashes")
    func bullets() {
        #expect(TextNormalizer.strippingBullet("• item") == "item")
        #expect(TextNormalizer.strippingBullet("- item") == "item")
        #expect(TextNormalizer.strippingBullet("— Bonjour, dit-il.") == "— Bonjour, dit-il.")
        #expect(TextNormalizer.strippingBullet("1. step") == "1. step")
    }

    @Test("Recognizes list markers")
    func listMarkers() {
        for line in ["• item", "- item", "* item", "1. item", "12) item", "a) item", "(iv) item", "– item"] {
            #expect(TextNormalizer.listMarker(in: line) != nil, "\(line)")
        }
        for line in ["-5 degrees", "2020 was", "A. Lincoln", "word"] {
            #expect(TextNormalizer.listMarker(in: line) == nil, "\(line)")
        }
    }
}

@Suite("Plain text")
struct PlainTextTests {
    @Test("Blank lines separate paragraphs; single newlines are wraps; list items stay separate")
    func wrappedParagraphs() {
        let text = """
        The first paragraph is wrapped
        across three lines with an exam-
        ple of hyphenation.

        Second paragraph.
        - first item
        - second item
        3. third item

        Last one.
        """
        #expect(PlainTextParagraphs.split(text) == [
            "The first paragraph is wrapped across three lines with an example of hyphenation.",
            "Second paragraph.", "first item", "second item", "3. third item", "Last one.",
        ])
    }

    @Test("Without blank lines, each line is a paragraph")
    func linePerParagraph() {
        #expect(PlainTextParagraphs.split("One.\r\nTwo.\rThree.\n") == ["One.", "Two.", "Three."])
    }

    @Test("Hard-wrapped text without blank lines is rejoined")
    func hardWrappedWithoutBlankLines() {
        let text = """
        It was a bright cold day in April, and the clocks were striking
        thirteen. Winston Smith, his chin nuzzled into his breast in an
        effort to escape the vile wind, slipped quickly through the glass
        doors of Victory Mansions.
          The hallway smelt of boiled cabbage and old rag mats. At one end
        of it a coloured poster, too large for indoor display, had been
        tacked to the wall.
        """
        let paragraphs = PlainTextParagraphs.split(text)
        #expect(paragraphs.count == 2, "\(paragraphs)")
        #expect(paragraphs.first?.hasSuffix("doors of Victory Mansions.") == true)
    }

    @Test("Detects encodings of text files", arguments: [
        ("utf16", String.Encoding.utf16),
        ("utf16le", .utf16LittleEndian),
        ("cp1252", .windowsCP1252),
        ("gb18030", String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))),
        ("shiftjis", .shiftJIS),
    ])
    func encodings(name: String, encoding: String.Encoding) async throws {
        let sample: String
        switch name {
        case "gb18030": sample = "这是一个中文文本文件，用于测试编码检测是否正确。我们需要足够多的文字才能可靠地判断。"
        case "shiftjis": sample = "これは日本語のテキストファイルです。文字コードの判定が正しく行われるかを確認します。"
        default: sample = "Café naïve façade – “quoted” text… with résumé and Ærø."
        }
        let dir = TemporaryDirectory()
        let url = try dir.write(sample, to: "\(name).txt", encoding: encoding)
        let result = try await ingest(.file(url))
        #expect(result.paragraphs == [sample])
        #expect(result.title == name)
    }

    @Test("Text input detects Markdown")
    func markdownDetection() async throws {
        let markdown = """
        # Notes

        Some **bold** words and a [link](https://example.com).

        ## Next

        - item
        """
        let result = try await ingest(.text(markdown))
        #expect(result.headings == ["Notes", "Next"])
        #expect(result.paragraphs == ["Some bold words and a link.", "item"])
        #expect(result.title == "Notes")

        let plain = try await ingest(.text("Just a note.\nWith two lines.\n\n- and a dash list\n- here"))
        #expect(plain.headings.isEmpty)
        #expect(plain.paragraphs == ["Just a note. With two lines.", "and a dash list", "here"])
        #expect(plain.title == "Just a note.")
    }

    @Test("Large text streams in several batches with progress")
    func streaming() async throws {
        let text = (1...1000).map { "Paragraph number \($0) has a few words." }.joined(separator: "\n\n")
        let result = try await ingest(.text(text))
        #expect(result.paragraphs.count == 1000)
        #expect(result.batches >= 4)
        #expect(result.progress.last == 1)
        #expect(result.progress == result.progress.sorted())
    }
}

@Suite("Markdown")
struct MarkdownTests {
    @Test("Headings, lists, quotes, images, front matter; code skipped; inline syntax stripped")
    func document() async throws {
        let dir = TemporaryDirectory()
        try dir.write(TestImages.png(width: 120, height: 80), to: "images/diagram one.png")
        let markdown = """
        ---
        title: "Front Matter Title"
        tags: [a, b]
        ---

        # The *Main* Heading

        A paragraph with **bold**, _italic_, `inline code`, and a [link](https://example.com)
        that wraps onto a second line &amp; has an entity.

        ![A diagram](images/diagram%20one.png)

        > A quoted line
        > continues here.

        1. First step
        2. Second step

        ```swift
        let x = 42
        print(x)
        ```

            indented prose block
            that is not code

        | Name | Value |
        |------|-------|
        | Pi   | 3.14  |

        <p>Raw <b>HTML</b> paragraph.</p>

        ![badge](https://img.shields.io/badge/build-passing-green.svg)

        ## Second Heading
        Final words.
        """
        let url = try dir.write(markdown, to: "notes.md")
        let result = try await ingest(.file(url))

        #expect(result.title == "Front Matter Title")
        #expect(result.headings == ["The Main Heading", "Second Heading"])
        #expect(result.paragraphs == [
            "A paragraph with bold, italic, inline code, and a link that wraps onto a second line & has an entity.",
            "A quoted line continues here.",
            "First step", "Second step",
            "indented prose block that is not code",
            "Name, Value", "Pi, 3.14",
            "Raw HTML paragraph.",
            "Final words.",
        ], "\(result.outline)")
        #expect(result.images.count == 1)
        let image = try #require(result.images.first)
        #expect(image.caption == "A diagram")
        #expect(image.pixelWidth == 120 && image.pixelHeight == 80)
        #expect(image.data != nil, "local images are read eagerly")
        #expect(!result.text.contains("let x"))
    }

    @Test("Front matter is removed even without a title")
    func frontMatter() {
        let (title, body) = FrontMatter.split("---\ndate: 2024\n---\nHello")
        #expect(title == nil)
        #expect(body == "Hello")
    }
}
