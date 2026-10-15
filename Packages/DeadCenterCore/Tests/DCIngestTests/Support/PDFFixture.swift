import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Draws PDF pages line by line with CoreText, so tests control the exact layout.
final class PDFFixtureBuilder {
    let pageSize = CGSize(width: 612, height: 792)
    let margin: CGFloat = 72
    /// The text column lines are set in (defaults to the page between the margins).
    var column: (x: CGFloat, width: CGFloat)?
    var textWidth: CGFloat { column?.width ?? pageSize.width - 2 * margin }

    private let data = NSMutableData()
    private let context: CGContext
    private(set) var pageCount = 0
    /// Baseline of the next line, from the bottom of the page.
    private(set) var cursor: CGFloat = 0

    init(title: String? = nil) {
        var box = CGRect(origin: .zero, size: pageSize)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, info as CFDictionary)!
    }

    func beginPage(top: CGFloat = 700) {
        context.beginPDFPage(nil)
        pageCount += 1
        cursor = top
    }

    func endPage() {
        context.endPDFPage()
    }

    /// Draws text with its baseline at `point`.
    func text(_ string: String, at point: CGPoint, size: CGFloat, bold: Bool = false) {
        let line = makeLine(string, size: size, bold: bold)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    func centered(_ string: String, y: CGFloat, size: CGFloat) {
        let line = makeLine(string, size: size, bold: false)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (pageSize.width - width) / 2, y: y)
        CTLineDraw(line, context)
    }

    /// Draws a line at the cursor and moves down by the leading. Justified lines fill the text width.
    func line(_ string: String, size: CGFloat = 11, indent: CGFloat = 0, justified: Bool = false, bold: Bool = false) {
        var line = makeLine(string, size: size, bold: bold)
        if justified, let stretched = CTLineCreateJustifiedLine(line, 1.0, Double(textWidth - indent)) {
            line = stretched
        }
        context.textPosition = CGPoint(x: (column?.x ?? margin) + indent, y: cursor)
        CTLineDraw(line, context)
        cursor -= size * 1.35
    }

    /// Lines of a paragraph: all justified except the last.
    func paragraph(_ lines: [String], indent: CGFloat = 0, lastLineJustified: Bool = false) {
        for (i, text) in lines.enumerated() {
            let isLast = i == lines.count - 1
            line(text, indent: i == 0 ? indent : 0, justified: !isLast || lastLineJustified)
        }
    }

    func space(_ points: CGFloat) {
        cursor -= points
    }

    /// Draws an image with its top edge at the cursor (centered unless `x` is given) and returns its rect.
    @discardableResult
    func image(_ image: CGImage, size: CGSize, x: CGFloat? = nil, top: CGFloat? = nil) -> CGRect {
        let rect = CGRect(x: x ?? (pageSize.width - size.width) / 2, y: (top ?? cursor) - size.height, width: size.width, height: size.height)
        context.draw(image, in: rect)
        if top == nil { cursor = rect.minY }
        return rect
    }

    /// Closes the document. Outline entries are (label, page index, destination top or nil for the page top).
    func finish(outline: [(String, Int, CGFloat?)] = []) -> Data {
        if !outline.isEmpty {
            let children: [[CFString: Any]] = outline.map { entry in
                var item: [CFString: Any] = [kCGPDFOutlineTitle: entry.0, kCGPDFOutlineDestination: entry.1 + 1]
                if let top = entry.2 {
                    let rect = CGRect(x: 0, y: top - 1, width: pageSize.width, height: 1)
                    item[kCGPDFOutlineDestinationRect] = rect.dictionaryRepresentation
                }
                return item
            }
            CGPDFContextSetOutline(context, [kCGPDFOutlineChildren: children] as CFDictionary)
        }
        context.closePDF()
        return data as Data
    }

    private func makeLine(_ string: String, size: CGFloat, bold: Bool) -> CTLine {
        let font = CTFontCreateWithName((bold ? "Times-Bold" : "Times-Roman") as CFString, size, nil)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        return CTLineCreateWithAttributedString(attributed)
    }
}

/// The main PDF fixture: running header and footer, a small logo on every page, hyphenation,
/// an indented paragraph, a figure, a paragraph spanning a page break, an outline, and a heading.
enum SamplePDF {
    static let title = "Dead Center Test PDF"
    static let header = "THE TEST DOCUMENT"

    static let p1 = "The quick brown fox jumps over the lazy dog while the morning sun rises slowly over the distant hills, and the valley below fills with light. This is a careful example of hyphenation that must be repaired."
    static let p2 = "A second paragraph begins with an indented first line, which is the most common way books mark a new paragraph when there is no extra space between paragraphs at all. It ends here."
    static let p3 = "The third paragraph is long enough to run off the bottom of the page, so its last line on this page stops in the middle of a sentence and this sentence continues onto the next page without any break in the middle of it, which the reader must stitch back together into one paragraph."
    static let p4 = "Some words are well-known compounds and keep their hyphen even when the line breaks inside them, while others were only split to make the text fit the column nicely."
    static let p5 = "Chapter two opens with a short paragraph that sits right under its heading."
    static let p6 = "The last page repeats a compound that is broken across two lines, the famous well-known phrase, and then finishes the document with a final sentence."

    static func make() -> Data {
        let pdf = PDFFixtureBuilder(title: title)
        let logo = TestImages.cgImage(width: 48, height: 48, red: 0.2, green: 0.6, blue: 0.2)
        let figure = TestImages.cgImage(width: 400, height: 300)
        var chapterTwoTop: CGFloat = 0

        func chrome(page: Int) {
            pdf.text(header, at: CGPoint(x: 72, y: 750), size: 9)
            pdf.image(logo, size: CGSize(width: 24, height: 24), x: 516, top: 762)
            pdf.centered("Page \(page) of 3", y: 40, size: 9)
        }

        pdf.beginPage()
        chrome(page: 1)
        pdf.line("Chapter One", size: 22, bold: true)
        pdf.space(6)
        pdf.paragraph([
            "The quick brown fox jumps over the lazy dog while the morning sun rises slowly over",
            "the distant hills, and the valley below fills with light. This is a careful exam-",
            "ple of hyphenation that must be repaired.",
        ])
        pdf.space(8)
        pdf.paragraph([
            "A second paragraph begins with an indented first line, which is the most common way",
            "books mark a new paragraph when there is no extra space between paragraphs at all. It",
            "ends here.",
        ], indent: 18)
        pdf.space(14)
        pdf.image(figure, size: CGSize(width: 216, height: 162))
        pdf.space(24)
        pdf.paragraph([
            "The third paragraph is long enough to run off the bottom of the page, so its last line",
            "on this page stops in the middle of a sentence and this sentence continues onto the",
        ], lastLineJustified: true)
        pdf.endPage()

        pdf.beginPage()
        chrome(page: 2)
        pdf.paragraph([
            "next page without any break in the middle of it, which the reader must stitch back",
            "together into one paragraph.",
        ])
        pdf.space(8)
        pdf.paragraph([
            "Some words are well-known compounds and keep their hyphen even when the line breaks",
            "inside them, while others were only split to make the text fit the column nicely.",
        ], lastLineJustified: false)
        pdf.space(20)
        chapterTwoTop = pdf.cursor + 24
        pdf.line("Chapter Two", size: 22, bold: true)
        pdf.space(6)
        pdf.paragraph(["Chapter two opens with a short paragraph that sits right under its heading."])
        pdf.endPage()

        pdf.beginPage()
        chrome(page: 3)
        pdf.line("A Final Section", size: 16, bold: true)
        pdf.space(4)
        pdf.paragraph([
            "The last page repeats a compound that is broken across two lines, the famous well-",
            "known phrase, and then finishes the document with a final sentence.",
        ])
        pdf.endPage()

        return pdf.finish(outline: [("Chapter One", 0, nil), ("Chapter Two", 1, chapterTwoTop)])
    }

    /// A long text-only PDF for timing the first batch.
    static func long(pages: Int) -> Data {
        let pdf = PDFFixtureBuilder(title: "Long Document")
        let sentences = [
            "Reading at speed depends on a steady stream of words arriving at exactly the right moment",
            "and every paragraph in this long document exists only to give the parser something to do",
            "while the test measures how quickly the first batch of blocks reaches the reader again",
        ]
        for page in 1...pages {
            pdf.beginPage(top: 720)
            pdf.text("Long Document", at: CGPoint(x: 72, y: 750), size: 9)
            pdf.centered("\(page)", y: 40, size: 9)
            for paragraph in 0..<8 {
                for line in 0..<5 {
                    pdf.line(sentences[(paragraph + line) % sentences.count] + (line == 4 ? "." : ""), justified: line < 4)
                }
                pdf.space(6)
            }
            pdf.endPage()
        }
        return pdf.finish()
    }

    static let columnsFirst = "Two columns are common in papers and magazines, and a paragraph that reaches the bottom of the left column carries on at the top of the right one without a break."
    static let columnsSecond = "The second paragraph starts with an indent in the right column and ends here."

    /// One page set in two columns, with a paragraph flowing from the left column into the right.
    static func twoColumns() -> Data {
        let pdf = PDFFixtureBuilder(title: "Columns")
        pdf.beginPage()
        pdf.column = (72, 216)
        pdf.paragraph([
            "Two columns are common in papers and",
            "magazines, and a paragraph that reaches",
            "the bottom of the left column carries on",
        ], lastLineJustified: true)
        let top: CGFloat = 700
        pdf.column = (324, 216)
        pdf.space(pdf.cursor - top)
        pdf.paragraph([
            "at the top of the right one without a",
            "break.",
        ])
        pdf.paragraph([
            "The second paragraph starts with an",
            "indent in the right column and ends here.",
        ], indent: 14)
        pdf.endPage()
        return pdf.finish()
    }

    /// Page 1 has a text layer; page 2 is a picture of text only (a scan).
    static func scanned() -> Data {
        let pdf = PDFFixtureBuilder()
        pdf.beginPage()
        pdf.paragraph(["This first page has a real text layer and reads normally."])
        pdf.endPage()
        pdf.beginPage()
        let scan = TestImages.textImage([
            "Scanned pages are read with optical",
            "character recognition when they have",
            "no text layer at all.",
        ], fontSize: 48, width: 1700)
        pdf.image(scan, size: CGSize(width: 468, height: 468 * CGFloat(scan.height) / CGFloat(scan.width)), top: 720)
        pdf.endPage()
        return pdf.finish()
    }
}
