import Foundation
import Testing
import DCModel
@testable import DCIngest

@Suite("EPUB")
struct EPUBTests {
    static let cover = TestImages.png(width: 300, height: 450, red: 0.1, green: 0.5, blue: 0.9)
    static let figure = TestImages.png(width: 200, height: 120)

    static func epub3(at url: URL) throws {
        try ZipFixture.write([
            (path: "mimetype", data: Data("application/epub+zip".utf8)),
            (path: "META-INF/container.xml", data: Data("""
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8)),
            (path: "OEBPS/content.opf", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title id="sub">A Subtitle</dc:title>
                <dc:title id="main">The Fixture Book</dc:title>
                <meta refines="#main" property="title-type">main</meta>
                <meta refines="#sub" property="title-type">subtitle</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="cover-page" href="cover.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch1" href="text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
                <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>
                <item id="fig" href="images/fig%201.png" media-type="image/png"/>
              </manifest>
              <spine>
                <itemref idref="cover-page"/><itemref idref="nav"/><itemref idref="ch1"/><itemref idref="ch2"/>
                <itemref idref="notes" linear="no"/>
              </spine>
            </package>
            """.utf8)),
            (path: "OEBPS/nav.xhtml", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>
            <body><nav epub:type="toc"><h1>Contents</h1><ol>
              <li><a href="text/chapter%201.xhtml">Chapter 1: Beginnings</a></li>
              <li><a href="text/ch2.xhtml#sec2">Chapter 2</a>
                <ol><li><a href="text/ch2.xhtml#sub">A Subsection</a></li></ol></li>
            </ol></nav>
            <nav epub:type="landmarks"><ol><li><a href="cover.xhtml">Cover</a></li></ol></nav></body></html>
            """.utf8)),
            (path: "OEBPS/cover.xhtml", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head>
            <body><div><img src="images/cover.png" alt="Cover"/></div></body></html>
            """.utf8)),
            (path: "OEBPS/text/chapter 1.xhtml", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Chapter 1</title><link rel="stylesheet" href="../style.css"/></head>
            <body><section epub:type="chapter">
            <h1>Chapter 1: Beginnings</h1>
            <p>First paragraph with&nbsp;an entity and <em>emphasis</em>.</p>
            <p><img src="../images/fig%201.png" alt="A red figure"/></p>
            <p>Second paragraph<a href="notes.xhtml#n1" epub:type="noteref">1</a> ends here.</p>
            <span epub:type="pagebreak" id="page12" title="12"/>
            <aside epub:type="footnote" id="fn1"><p>Footnote text.</p></aside>
            </section></body></html>
            """.utf8)),
            (path: "OEBPS/text/ch2.xhtml", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title></head><body>
            <p>Intro text before section two.</p>
            <section id="sec2"><h2>Chapter 2</h2><p>Section text.</p>
            <h3 id="sub">A Subsection</h3><p>Sub text.</p></section>
            </body></html>
            """.utf8)),
            (path: "OEBPS/text/notes.xhtml", data: Data("<html><body><p id=\"n1\">A note.</p></body></html>".utf8)),
            (path: "OEBPS/images/cover.png", data: cover),
            (path: "OEBPS/images/fig 1.png", data: figure),
        ], to: url)
    }

    @Test("EPUB 3: nav TOC with anchors, cover first, images, no repeated titles or footnotes")
    func epub3() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("book.epub")
        try Self.epub3(at: url)
        let result = try await ingest(.file(url))

        #expect(result.title == "The Fixture Book")
        let expected = """
        [I]
        [C] Chapter 1: Beginnings
        [P] First paragraph with an entity and emphasis.
        [I] A red figure
        [P] Second paragraph ends here.
        [P] Intro text before section two.
        [C] Chapter 2
        [P] Section text.
        [C] A Subsection
        [P] Sub text.
        """
        #expect(result.outline == expected)
        #expect(result.images.first?.data == Self.cover)
        #expect(result.images.last?.data == Self.figure)
        #expect(result.progress.last == 1)
        #expect(result.batches >= 3, "one spine item per batch")
    }

    @Test("EPUB 2: NCX table of contents and cover meta")
    func epub2() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("old.epub")
        try ZipFixture.write([
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """),
            ("content.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <opf:package xmlns:opf="http://www.idpf.org/2007/opf" version="2.0">
            <opf:metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>An Older Book</dc:title><opf:meta name="cover" content="cover-img"/></opf:metadata>
            <opf:manifest>
              <opf:item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
              <opf:item id="toc" href="toc.html" media-type="application/xhtml+xml"/>
              <opf:item id="c1" href="content/one.html" media-type="application/xhtml+xml"/>
              <opf:item id="c2" href="content/two.html" media-type="application/xhtml+xml"/>
              <opf:item id="cover-img" href="art/front.png" media-type="image/png"/>
            </opf:manifest>
            <opf:spine toc="ncx"><opf:itemref idref="toc"/><opf:itemref idref="c1"/><opf:itemref idref="c2"/></opf:spine>
            </opf:package>
            """),
            ("toc.ncx", """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
              <navPoint id="p1" playOrder="1"><navLabel><text>One</text></navLabel><content src="content/one.html"/></navPoint>
              <navPoint id="p2" playOrder="2"><navLabel><text>Two &amp; More</text></navLabel><content src="content/two.html#start"/></navPoint>
            </navMap></ncx>
            """),
            ("toc.html", """
            <html><body><h1>Contents</h1><p><a href="content/one.html">One</a></p><p><a href="content/two.html">Two</a></p>
            <p><a href="content/one.html#a">A</a></p><p><a href="content/one.html#b">B</a></p><p><a href="content/two.html#c">C</a></p></body></html>
            """),
            ("content/one.html", "<html><head><title>One</title></head><body><h2>One</h2><p>Old style &mdash; with an em dash.</p><p><img src=\"../art/front.png\"/></p></body></html>"),
            ("content/two.html", "<html><body><p>Before.</p><h2 id=\"start\">Two &amp; More</h2><p>After.</p></body></html>"),
        ].map { (path: $0.0, data: Data($0.1.utf8)) } + [(path: "art/front.png", data: Self.cover)], to: url)

        let result = try await ingest(.file(url))
        #expect(result.title == "An Older Book")
        #expect(result.outline == """
        [I]
        [C] One
        [P] Old style — with an em dash.
        [P] Before.
        [C] Two & More
        [P] After.
        """)
    }

    @Test("Unpacked EPUB directories are read too")
    func directoryPackage() async throws {
        let dir = TemporaryDirectory()
        let zip = dir.file("book.epub")
        try Self.epub3(at: zip)
        let package = ZipPackage(zip)
        let folder = dir.file("Unpacked.epub")
        for path in package.paths {
            try dir.write(package.data(at: path)!, to: "Unpacked.epub/\(path)")
        }
        let result = try await ingest(.file(folder))
        #expect(result.title == "The Fixture Book")
        #expect(result.chapters == ["Chapter 1: Beginnings", "Chapter 2", "A Subsection"])
    }

    @Test("DRM-protected books are refused politely")
    func drm() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("locked.epub")
        try ZipFixture.write([
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"a.opf\"/></rootfiles></container>"),
            ("META-INF/encryption.xml", """
            <encryption><EncryptedData><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <CipherData><CipherReference URI="text/ch1.xhtml"/></CipherData></EncryptedData></encryption>
            """),
            ("a.opf", "<package><manifest/><spine/></package>"),
        ], to: url)
        do {
            _ = try await ingest(.file(url))
            Issue.record("expected an error")
        } catch let error as IngestError {
            #expect(error.localizedDescription.contains("DRM"))
        }
    }

    @Test("Package paths resolve relative references")
    func paths() {
        #expect(PackagePath.resolve("../images/fig%201.png#x", against: "OEBPS/text") == "OEBPS/images/fig 1.png")
        #expect(PackagePath.resolve("/root.png", against: "a/b") == "root.png")
        #expect(PackagePath.resolve("https://example.com/x.png", against: "a") == nil)
        #expect(PackagePath.fragment(of: "ch.xhtml#sec%202") == "sec 2")
    }
}

private extension ZipPackage {
    convenience init(_ url: URL) {
        try! self.init(url: url)
    }
}
