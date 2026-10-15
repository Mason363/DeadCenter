import CoreGraphics
import Foundation
import PDFKit
import Testing
import DCModel
@testable import DCIngest

@Suite("Layout heuristics")
struct HeuristicsTests {
    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 12) -> TextLine {
        TextLine(text: text, rect: CGRect(x: x, y: y, width: width, height: height))
    }

    private func paragraphs(_ lines: [TextLine]) -> [String] {
        var builder = LineParagraphBuilder()
        builder.bodyLineHeight = 12
        return (builder.addPage(lines: lines) + builder.finish()).compactMap { if case .paragraph(let t) = $0 { t } else { nil } }
    }

    @Test("Hanging-indent list items keep their continuation lines")
    func hangingIndent() {
        let result = paragraphs([
            line("Intro sentence that is long enough to fill the whole line of the column here.", x: 72, y: 700, width: 460),
            line("− First item wraps onto a second line because it is quite long and", x: 90, y: 686, width: 440),
            line("continues here.", x: 108, y: 672, width: 90),
            line("− Second item also wraps onto the next line because it is long and it", x: 90, y: 658, width: 442),
            line("ends here.", x: 108, y: 644, width: 60),
        ])
        #expect(result == [
            "Intro sentence that is long enough to fill the whole line of the column here.",
            "− First item wraps onto a second line because it is quite long and continues here.",
            "− Second item also wraps onto the next line because it is long and it ends here.",
        ])
    }

    @Test("Short lines (addresses, verse) stay separate; CJK lines join without spaces")
    func shortLines() {
        let result = paragraphs([
            line("Please write to us at the address below if you have any questions at all.", x: 72, y: 700, width: 460),
            line("Example Corporation", x: 72, y: 686, width: 110),
            line("1 Infinite Loop", x: 72, y: 672, width: 85),
            line("Cupertino", x: 72, y: 658, width: 55),
            line("这是一个很长的中文段落，它在第一行没有结束，而是继续到下一行，所以", x: 72, y: 630, width: 460),
            line("应该连在一起。", x: 72, y: 616, width: 90),
        ])
        #expect(result == [
            "Please write to us at the address below if you have any questions at all.",
            "Example Corporation", "1 Infinite Loop", "Cupertino",
            "这是一个很长的中文段落，它在第一行没有结束，而是继续到下一行，所以应该连在一起。",
        ])
    }

    @Test("Fragments of one printed line are merged")
    func fragments() {
        let merged = PDFPageAnalyzer.mergingFragments([
            line("CAREFULLY BEFORE USING THE SOFTWARE.", x: 72, y: 660, width: 360),
            line("THIS IS A LEGAL", x: 438, y: 660, width: 80),
            line("AGREEMENT BETWEEN US.", x: 72, y: 648, width: 200),
        ])
        #expect(merged.map(\.text) == ["CAREFULLY BEFORE USING THE SOFTWARE. THIS IS A LEGAL", "AGREEMENT BETWEEN US."])
    }

    @Test("Table-of-contents dot leaders are dropped")
    func dotLeaders() {
        #expect(PDFPageAnalyzer.withoutDotLeader("1. Introduction ........................ 12") == "1. Introduction")
        #expect(PDFPageAnalyzer.withoutDotLeader("Preface . . . . . . . xiv") == "Preface")
        #expect(PDFPageAnalyzer.withoutDotLeader("Wait... what?") == "Wait... what?")
    }

    @Test("OCR fragments are ordered by column")
    func ocrColumns() {
        var fragments: [TextLine] = []
        for row in 0..<6 {
            let y = CGFloat(700 - row * 20)
            fragments.append(line("right \(row)", x: 320, y: y, width: 200))
            fragments.append(line("left \(row)", x: 72, y: y, width: 200))
        }
        fragments.append(line("A Title Across Both Columns", x: 72, y: 760, width: 448, height: 20))
        let ordered = OCRLayout.readingOrder(fragments.shuffled(), pageWidth: 612).map(\.text)
        #expect(ordered == ["A Title Across Both Columns"] + (0..<6).map { "left \($0)" } + (0..<6).map { "right \($0)" })
    }

    @Test("Plain-text emphasis markers are removed")
    func underscores() {
        #expect(PlainTextParagraphs.strippingUnderscoreEmphasis("so _very_ remarkable, _took a watch_ out; snake_case_name stays")
                == "so very remarkable, took a watch out; snake_case_name stays")
    }

    @Test("Hard-wrapped text: short lines such as a contents list stay separate")
    func hardWrappedContents() {
        let body = (0..<6).map { _ in "This line of a hard-wrapped book runs almost all the way to the margin" }.joined(separator: "\r\n")
        let text = body + ".\r\n\r\n Contents\r\n CHAPTER I. Down the Rabbit-Hole\r\n CHAPTER II. The Pool of Tears\r\n\r\n" + body + "."
        let paragraphs = PlainTextParagraphs.split(text)
        #expect(paragraphs.count == 5, "\(paragraphs)")
        #expect(paragraphs[1...3] == ["Contents", "CHAPTER I. Down the Rabbit-Hole", "CHAPTER II. The Pool of Tears"])
    }

    @Test("CRLF Markdown with front matter")
    func crlfMarkdown() {
        let (title, body) = FrontMatter.split("---\r\ntitle: Windows\r\n---\r\n# Heading\r\nText")
        #expect(title == "Windows")
        #expect(MarkdownReader.blocks(from: body, baseURL: nil) == [.heading("Heading", level: 1), .paragraph("Text")])
    }

    @Test("HTML charset sniffing")
    func charsetSniffing() {
        let html = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=Shift_JIS\"></head><body>日本語の文章</body></html>"
        let decoded = TextDecoding.decodeHTML(html.data(using: .shiftJIS)!)
        #expect(decoded.contains("日本語の文章"))
        #expect(TextDecoding.decodeHTML(Data("<p>café</p>".utf8), transportCharset: "utf-8") == "<p>café</p>")
    }

    @Test("Footnote markers and empty brackets disappear from HTML")
    func footnoteMarkers() async throws {
        let html = """
        <p>The claim stands.<font color="#999">[<a href="#f1n">1</a>]</font> More text.</p>
        <p>[2]</p>
        <p>Wikipedia says so.<sup class="noprint">[<i><a href="/wiki/x">citation needed</a></i>]</sup></p>
        <h2>Section <span class="mw-editsection">[<a href="/edit">edit</a>]</span></h2>
        <div class="reflist"><ol><li>A reference.</li></ol></div>
        """
        let result = try await ingest(.html(html, baseURL: nil))
        #expect(result.outline == """
        [P] The claim stands. More text.
        [P] Wikipedia says so.
        [H2] Section
        """)
    }

    @Test("Link lists and contents tables are skipped")
    func linkLists() async throws {
        let rows = (1...5).map { "<tr><td><a href=\"ch\($0).xhtml\">CHAPTER \($0).</a></td><td>Title \($0)</td></tr>" }.joined()
        let html = """
        <p>Before the lists.</p>
        <table>\(rows)</table>
        <ul><li><a href="/a">Alpha</a></li><li><a href="/b">Beta</a></li><li><a href="/c">Gamma</a></li><li><a href="/d">Delta</a></li></ul>
        <p>A paragraph with <a href="/x">one link</a> stays.</p>
        """
        let result = try await ingest(.html(html, baseURL: nil))
        #expect(result.paragraphs == ["Before the lists.", "A paragraph with one link stays."])
    }

    @Test("The PDF worker gives up on slow work and keeps going")
    func workerTimeout() throws {
        let dir = TemporaryDirectory()
        let url = try dir.write(SamplePDF.long(pages: 2), to: "two.pdf")
        let worker = try PDFWorker(url: url)
        let slow = try worker.run(timeout: 0.2) { _ in Thread.sleep(forTimeInterval: 1); return 1 }
        #expect(slow == nil)
        let count = try worker.run(timeout: 5) { $0.pageCount }
        #expect(count == 2)
    }
}
