import AppKit
import Foundation
import Testing
import DCModel
@testable import DCIngest

@Suite("Rich text")
struct RichTextTests {
    static func sample(withImage: Bool) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica", size: 12)!]
        s.append(NSAttributedString(string: "A Big Title\n", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 26)!]))
        s.append(NSAttributedString(string: "The first body paragraph has ordinary text in it.\n", attributes: body))
        s.append(NSAttributedString(string: "A Bold Subheading\n", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 12)!]))
        s.append(NSAttributedString(string: "Another paragraph\u{2028}with a soft line break and a ﬁ ligature.\n", attributes: body))
        if withImage {
            let wrapper = FileWrapper(regularFileWithContents: TestImages.png(width: 160, height: 90))
            wrapper.preferredFilename = "picture.png"
            s.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            s.append(NSAttributedString(string: "\n", attributes: body))
        }
        let list = NSMutableParagraphStyle()
        list.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        var listAttributes = body
        listAttributes[.paragraphStyle] = list
        s.append(NSAttributedString(string: "\t•\tA list item\n", attributes: listAttributes))
        s.append(NSAttributedString(string: "Closing paragraph.", attributes: body))
        return s
    }

    static let expected = """
    [H1] A Big Title
    [P] The first body paragraph has ordinary text in it.
    [H4] A Bold Subheading
    [P] Another paragraph with a soft line break and a fi ligature.
    [P] A list item
    [P] Closing paragraph.
    """

    @Test("RTF: headings by size and weight, clean paragraphs", arguments: [
        ("rtf", NSAttributedString.DocumentType.rtf),
        ("odt", .openDocument),
        ("doc", .docFormat),
    ])
    func formats(ext: String, type: NSAttributedString.DocumentType) async throws {
        let s = Self.sample(withImage: false)
        let data = try s.data(from: NSRange(location: 0, length: s.length),
                              documentAttributes: [.documentType: type, .title: "Rich Title"])
        let dir = TemporaryDirectory()
        let url = try dir.write(data, to: "doc.\(ext)")
        let result = try await ingest(.file(url))
        #expect(result.outline == Self.expected, "\(ext)")
        #expect(result.title == "Rich Title" || result.title == "doc", "\(ext)")
    }

    @Test("RTFD: attachments become images in place")
    func rtfd() async throws {
        let s = Self.sample(withImage: true)
        let wrapper = try s.fileWrapper(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let dir = TemporaryDirectory()
        let url = dir.file("pictures.rtfd")
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        let result = try await ingest(.file(url))
        #expect(result.images.count == 1)
        #expect(result.images.first?.pixelWidth == 160)
        let kinds = result.outline.split(separator: "\n").map { String($0.prefix(3)) }
        #expect(kinds == ["[H1", "[P]", "[H4", "[P]", "[I]", "[P]", "[P]"], "\(result.outline)")
        #expect(result.title == "pictures")
    }

    @Test("Pasteboard RTF data")
    func rtfData() async throws {
        let s = Self.sample(withImage: false)
        let data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let result = try await ingest(.rtf(data))
        #expect(result.outline == Self.expected)
        await #expect(throws: IngestError.self) { try await ingest(.rtf(Data("not rtf".utf8))) }
    }

    @Test("DOCX: heading styles, images, tables, text boxes; tables of contents skipped")
    func docx() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("report.docx")
        let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006""#
        let drawing = """
        <w:drawing><wp:inline><wp:extent cx="1905000" cy="952500"/><wp:docPr id="1" name="Picture 1" descr="A chart of results"/>
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>
        <pic:blipFill><a:blip r:embed="rId9"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(w)><w:body>
        <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Annual Report</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="TOC1"/></w:pPr><w:r><w:t>Introduction ........ 1</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Introduction</w:t></w:r></w:p>
        <w:p><w:r><w:t xml:space="preserve">This year </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>went well</w:t></w:r><w:r><w:t>, as the </w:t></w:r><w:hyperlink r:id="rId3"><w:r><w:t>results page</w:t></w:r></w:hyperlink><w:r><w:t xml:space="preserve"> shows.</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r></w:p>
        <w:p><w:r>\(drawing)</w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="MyHeading"/></w:pPr><w:r><w:t>Custom Styled Heading</w:t></w:r></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell one</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Cell two</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:p><w:r><w:t>Deleted </w:t></w:r><w:del><w:r><w:delText>old words </w:delText></w:r></w:del><w:r><w:t>text was removed.</w:t></w:r></w:p>
        <w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><w:txbxContent><w:p><w:r><w:t>Text box content.</w:t></w:r></w:p></w:txbxContent></w:drawing></mc:Choice><mc:Fallback><w:pict><w:txbxContent><w:p><w:r><w:t>Text box content.</w:t></w:r></w:p></w:txbxContent></w:pict></mc:Fallback></mc:AlternateContent></w:r></w:p>
        <w:sectPr/></w:body></w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?><w:styles \(w)>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="MyHeading"><w:name w:val="My Heading"/><w:basedOn w:val="Heading2"/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/></w:style>
        <w:style w:type="paragraph" w:styleId="TOC1"><w:name w:val="toc 1"/></w:style>
        </w:styles>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com" TargetMode="External"/>
        </Relationships>
        """
        let core = """
        <?xml version="1.0" encoding="UTF-8"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Report Title</dc:title></cp:coreProperties>
        """
        try ZipFixture.write([
            (path: "[Content_Types].xml", data: Data("<Types/>".utf8)),
            (path: "word/document.xml", data: Data(document.utf8)),
            (path: "word/styles.xml", data: Data(styles.utf8)),
            (path: "word/_rels/document.xml.rels", data: Data(rels.utf8)),
            (path: "docProps/core.xml", data: Data(core.utf8)),
            (path: "word/media/image1.png", data: TestImages.png(width: 250, height: 125)),
        ], to: url)

        let result = try await ingest(.file(url))
        #expect(result.title == "Report Title")
        #expect(result.outline == """
        [H1] Annual Report
        [H1] Introduction
        [P] This year went well, as the results page shows.
        [I] A chart of results
        [H2] Custom Styled Heading
        [P] Cell one
        [P] Cell two
        [P] Deleted text was removed.
        [P] Text box content.
        """)
        #expect(result.images.first?.pixelWidth == 250)
    }

    @Test("DOCX written by AppKit (no images) still reads")
    func appKitDOCX() async throws {
        let s = Self.sample(withImage: false)
        let data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let dir = TemporaryDirectory()
        let url = try dir.write(data, to: "appkit.docx")
        let result = try await ingest(.file(url))
        #expect(result.text.contains("The first body paragraph has ordinary text in it."))
        #expect(result.text.contains("Closing paragraph."))
    }
}

@Suite("Image OCR")
struct ImageOCRTests {
    @Test("Reads text in images")
    func ocr() async throws {
        let image = TestImages.textImage(["Dead Center reads the words", "in this picture aloud."], fontSize: 44)
        let result = try await ingest(.image(TestImages.encode(image, type: .png)))
        #expect(result.text.lowercased().contains("dead center reads the words in this picture aloud"), "\(result.outline)")
        #expect(result.images.isEmpty)

        let dir = TemporaryDirectory()
        let url = try dir.write(TestImages.encode(image, type: .jpeg), to: "Photo of text.jpg")
        let file = try await ingest(.file(url))
        #expect(file.title == "Photo of text")
        #expect(file.text.lowercased().contains("in this picture"))
    }

    @Test("An image without text is empty")
    func noText() async throws {
        do {
            _ = try await ingest(.image(TestImages.png(width: 400, height: 300)))
            Issue.record("expected .empty")
        } catch let error as IngestError {
            guard case .empty = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test("Undecodable image data is unreadable")
    func garbage() async throws {
        await #expect(throws: IngestError.self) { try await ingest(.image(Data("nope".utf8))) }
    }
}
