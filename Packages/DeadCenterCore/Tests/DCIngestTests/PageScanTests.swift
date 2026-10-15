import CoreGraphics
import Foundation
import Testing
import DCModel
@testable import DCIngest

@Suite("Page scans", .serialized)
struct PageScanTests {
    static let page = ScanFixture.textbookPage()
    static let flat = TestImages.encode(page, type: .png)
    static let photo = ScanFixture.photo(of: page)

    /// Scans and returns the result with the time per page.
    private func scan(_ source: ScanSource, pages: Int = 1) async throws -> (IngestResult, Duration) {
        let start = ContinuousClock.now
        let result = try await ingest(.scan(source))
        return (result, (ContinuousClock.now - start) / pages)
    }

    /// Everything the textbook page should read as, whether scanned flat or photographed.
    private func expectTextbook(_ result: IngestResult, wordRecall: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result.title == ScanFixture.heading, sourceLocation: sourceLocation)
        #expect(result.headings == [ScanFixture.heading], "\(result.outline)", sourceLocation: sourceLocation)

        // Paragraphs come out whole and in column order: left column, then right, then the closing paragraph.
        let expected = ScanFixture.paragraphs
        #expect(result.paragraphs.count == expected.count, "\(result.outline)", sourceLocation: sourceLocation)
        for (paragraph, wanted) in zip(result.paragraphs, expected) {
            #expect(ScanFixture.recall(of: wanted, in: paragraph) >= wordRecall, "\(paragraph)", sourceLocation: sourceLocation)
        }
        let text = result.text
        #expect(text.contains("vapor by evaporation, which"), sourceLocation: sourceLocation)
        #expect(!text.contains("evapo-") && !text.contains("evapo ration"), sourceLocation: sourceLocation)

        // Running header and page number are gone; so are the figure's labels, its caption, and the garbled equation.
        #expect(!text.uppercased().contains("EARTH SCIENCE") && !text.contains(ScanFixture.pageNumber), sourceLocation: sourceLocation)
        for label in ScanFixture.labels { #expect(!text.contains(label), sourceLocation: sourceLocation) }
        #expect(!text.contains("Figure 2.3"), sourceLocation: sourceLocation)
        #expect(!text.contains("="), "\(result.outline)", sourceLocation: sourceLocation)

        // One figure with its caption, after the right column; the equation as an image where it stood.
        let figures = result.images.filter { $0.caption != nil }
        #expect(figures.count == 1, "\(result.outline)", sourceLocation: sourceLocation)
        #expect(figures.first?.caption?.contains("Figure 2.3") == true, sourceLocation: sourceLocation)
        #expect(figures.first?.caption?.hasSuffix("the air and the land.") == true, sourceLocation: sourceLocation)
        #expect(result.images.count == 2, "\(result.outline)", sourceLocation: sourceLocation)
        let kinds = result.blocks.map { block -> String in
            switch block {
            case .chapter: "C"
            case .heading: "H"
            case .paragraph: "P"
            case .image(let asset): asset.caption == nil ? "E" : "F"
            }
        }.joined()
        #expect(kinds == "HPPEPPPPFP", "\(result.outline)", sourceLocation: sourceLocation)
        #expect(result.progress.last == 1, sourceLocation: sourceLocation)
    }

    @Test("A flat textbook page: columns, dehyphenation, running heads, a captioned figure and an equation")
    func flatPage() async throws {
        let (result, perPage) = try await scan(.images([Self.flat]))
        expectTextbook(result, wordRecall: 0.97)
        #expect(perPage < .seconds(2), "took \(perPage)")

        let figure = try #require(result.images.first { $0.caption != nil })
        let size = try #require(figure.data.flatMap(ImageData.pixelSize(of:)))
        // The figure is 1240 × 660 on the page; the crop adds a little padding.
        #expect(abs(size.width - 1240) <= 80 && abs(size.height - 660) <= 80, "\(size)")
        let equation = try #require(result.images.first { $0.caption == nil })
        #expect((equation.pixelHeight ?? 0) < 120 && (equation.pixelWidth ?? 0) < 400, "\(equation)")
    }

    @Test("A photo of the page is found, flattened, and reads like the flat scan")
    func photographedPage() async throws {
        let (flat, _) = try await scan(.images([Self.flat]))
        let (photo, perPage) = try await scan(.images([Self.photo]))
        expectTextbook(photo, wordRecall: 0.9)
        #expect(perPage < .seconds(2), "took \(perPage)")
        #expect(ScanFixture.recall(of: flat.text, in: photo.text) >= 0.9)

        // Flattening restores the page's proportions, so the figure keeps its shape.
        let flatFigure = try #require(flat.images.first { $0.caption != nil })
        let photoFigure = try #require(photo.images.first { $0.caption != nil })
        let flatAspect = Double(flatFigure.pixelWidth ?? 0) / Double(max(flatFigure.pixelHeight ?? 1, 1))
        let photoAspect = Double(photoFigure.pixelWidth ?? 0) / Double(max(photoFigure.pixelHeight ?? 1, 1))
        #expect(abs(photoAspect / flatAspect - 1) < 0.06, "\(flatAspect) vs \(photoAspect)")
    }

    @Test("A page on its side or upside down is turned upright")
    func turnedPages() async throws {
        let clockwise = ScanFixture.rotated(Self.page, clockwise: true)
        for turned in [clockwise, ScanFixture.rotated(Self.page, clockwise: false), ScanFixture.rotated(clockwise, clockwise: true)] {
            let (result, perPage) = try await scan(.images([TestImages.encode(turned, type: .png)]))
            #expect(result.title == ScanFixture.heading)
            #expect(result.paragraphs.count == ScanFixture.paragraphs.count, "\(result.outline)")
            #expect(ScanFixture.recall(of: ScanFixture.paragraphs.joined(separator: " "), in: result.text) >= 0.95)
            #expect(result.images.filter { $0.caption?.hasPrefix("Figure 2.3") == true }.count == 1, "\(result.outline)")
            for label in ScanFixture.labels { #expect(!result.text.contains(label)) }
            #expect(perPage < .seconds(3), "took \(perPage)")
        }
    }

    @Test("A paper page: a ruled table captioned above, a chart captioned below, a footnote")
    func paperPage() async throws {
        let page = ScanFixture.paperPage()
        for source in [TestImages.encode(page, type: .png), ScanFixture.photo(of: page)] {
            let (result, perPage) = try await scan(.images([source]))
            #expect(result.title == "Notes on River Sediment")
            let captions = result.images.compactMap(\.caption)
            #expect(captions.count == 2 && result.images.count == 2, "\(result.outline)")
            #expect(captions.first?.hasPrefix("Table 1") == true && captions.last?.hasPrefix("Fig. 2.") == true, "\(captions)")
            let text = result.text
            for cell in ScanFixture.tableCells.joined() where cell != "River" {
                #expect(!text.contains(cell), "\(cell) leaked: \(result.outline)")
            }
            for tick in ["150", "200"] { #expect(!text.contains(tick), "\(result.outline)") }
            #expect(!result.paragraphs.contains("7"), "page number")
            let intro = ScanFixture.paperIntro.reduce("") { TextNormalizer.join($0, $1) }
            #expect(result.paragraphs.contains { ScanFixture.recall(of: intro, in: $0) >= 0.97 }, "\(result.outline)")
            #expect(result.paragraphs.last.map { ScanFixture.recall(of: ScanFixture.paperFootnote, in: $0) >= 0.9 } == true)
            #expect(perPage < .seconds(2), "took \(perPage)")
        }
    }

    @Test("Layouts: a tinted box of prose stays text, full-width figures split columns into bands, margin notes go")
    func layouts() async throws {
        let (sidebar, _) = try await scan(.images([TestImages.encode(ScanFixture.sidebarPage(), type: .png)]))
        #expect(sidebar.images.isEmpty, "\(sidebar.outline)")
        let box = ScanFixture.sidebarText.reduce("") { TextNormalizer.join($0, $1) }
        #expect(sidebar.paragraphs.last.map { ScanFixture.recall(of: box, in: $0) >= 0.97 } == true, "\(sidebar.outline)")

        let (banded, _) = try await scan(.images([TestImages.encode(ScanFixture.bandedPage(), type: .png)]))
        let kinds = banded.blocks.map { if case .image = $0 { "I" } else { "P" } }.joined()
        #expect(kinds == "PPIPP", "\(banded.outline)")
        let order = [ScanFixture.leftColumn[0][0], ScanFixture.rightColumn[1][0], ScanFixture.rightColumn[2][0], ScanFixture.rightColumn[3][0]]
        #expect(banded.paragraphs.map { String($0.prefix(20)) } == order.map { String($0.prefix(20)) }, "\(banded.outline)")

        let (notes, _) = try await scan(.images([TestImages.encode(ScanFixture.marginNotePage(), type: .png)]))
        #expect(notes.paragraphs.count == 3, "\(notes.outline)")
        #expect(!notes.text.contains("Key term"), "\(notes.outline)")
    }

    @Test("A page that's only a picture is shown whole; a blank page is empty")
    func pagesWithoutText() async throws {
        let (figure, _) = try await scan(.images([TestImages.encode(ScanFixture.figurePage(), type: .png)]))
        #expect(figure.blocks.count == 1 && figure.images.count == 1, "\(figure.outline)")
        for label in ScanFixture.labels { #expect(!figure.text.contains(label)) }

        let blank = ScanFixture.photo(of: PageCanvas(size: ScanFixture.pageSize).image())
        await #expect(throws: IngestError.self) { try await ingest(.scan(.images([blank]))) }
    }

    @Test("Running heads repeated across pages are dropped, and paragraphs continue over page breaks")
    func multiplePages() async throws {
        let pages = ScanFixture.bookImages()
        let dir = TemporaryDirectory()
        let url = try dir.write(ScanFixture.tiff(pages), to: "Rivers.tiff")
        let (result, perPage) = try await scan(.file(url), pages: pages.count)
        #expect(result.title == "Rivers")
        #expect(result.paragraphs.count == ScanFixture.bookParagraphs.count, "\(result.outline)")
        for (paragraph, wanted) in zip(result.paragraphs, ScanFixture.bookParagraphs) {
            #expect(ScanFixture.recall(of: wanted, in: paragraph) >= 0.97, "\(paragraph)")
        }
        #expect(!result.text.contains(ScanFixture.bookHeader), "\(result.outline)")
        #expect(!result.text.contains("Page 4"))
        #expect(result.images.isEmpty, "\(result.outline)")
        #expect(perPage < .seconds(2), "took \(perPage)")
        #expect(result.progress == result.progress.sorted() && result.progress.last == 1)

        // The same pages as separate images, with no title to go on.
        let images = try await ingest(.scan(.images(pages.map { TestImages.encode($0, type: .jpeg) })))
        #expect(images.title == "Scan")
        #expect(!images.text.contains(ScanFixture.bookHeader))
        #expect(images.paragraphs.count == ScanFixture.bookParagraphs.count, "\(images.outline)")
    }

    @Test("Plain pages and screenshots read normally through the scan path")
    func ordinaryImages() async throws {
        let plain = TestImages.textImage(["Dead Center reads the words", "in this picture aloud."], fontSize: 44)
        let (text, _) = try await scan(.images([TestImages.encode(plain, type: .png)]))
        #expect(text.text.lowercased().contains("dead center reads the words in this picture aloud"), "\(text.outline)")
        #expect(text.images.isEmpty)

        let (screenshot, _) = try await scan(.images([TestImages.encode(ScanFixture.screenshot(), type: .png)]))
        let note = ScanFixture.screenshotNote.reduce("") { TextNormalizer.join($0, $1) }
        #expect(screenshot.paragraphs.contains { ScanFixture.recall(of: note, in: $0) >= 0.97 }, "\(screenshot.outline)")
        #expect(screenshot.images.isEmpty, "\(screenshot.outline)")
    }

    @Test("Scanned PDFs are scanned; PDFs with a text layer read as usual")
    func pdfs() async throws {
        let dir = TemporaryDirectory()
        let scanned = try dir.write(ScanFixture.scannedPDF([Self.page]), to: "Scan 2024-03-01.pdf")
        let (result, perPage) = try await scan(.file(scanned))
        #expect(result.title == ScanFixture.heading)
        #expect(ScanFixture.recall(of: ScanFixture.paragraphs.joined(separator: " "), in: result.text) >= 0.95, "\(result.outline)")
        #expect(result.images.filter { $0.caption?.hasPrefix("Figure 2.3") == true }.count == 1, "\(result.outline)")
        #expect(perPage < .seconds(2), "took \(perPage)")

        let text = try dir.write(SamplePDF.make(), to: "sample.pdf")
        let (viaScan, _) = try await scan(.file(text))
        let direct = try await ingest(.file(text))
        #expect(viaScan.blocks == direct.blocks)
        #expect(viaScan.title == SamplePDF.title)
    }

    @Test("Nothing to scan, or nothing decodable, is reported")
    func unreadable() async throws {
        await #expect(throws: IngestError.self) { try await ingest(.scan(.images([Data("nope".utf8)]))) }
        await #expect(throws: IngestError.self) { try await ingest(.scan(.images([]))) }
        await #expect(throws: IngestError.self) { try await ingest(.scan(.file(URL(fileURLWithPath: "/nonexistent/page.jpg")))) }
    }
}

@Suite("Page scan heuristics")
struct PageScanHeuristicsTests {
    @Test("Captions are recognized by how they open")
    func captions() {
        for text in ["Figure 2.3 The water cycle", "Fig. 4: Rainfall", "FIGURE 12", "Table IV Results", "Source: NASA", "Chart 3.1 Runoff", "Photo: J. Smith"] {
            #expect(FigureDetector.isCaptionStart(text), "\(text)")
        }
        for text in ["Table salt dissolves in water", "Figures of speech are common", "Photographers often wait", "Sources of water include", "The figure shows"] {
            #expect(!FigureDetector.isCaptionStart(text), "\(text)")
        }
    }

    @Test("Display equations are told from prose")
    func math() {
        for text in ["P=E+R+ 4S", "x = 5", "E = mc2", "f(x) = ∫ g(t) dt", "a² + b² = c²"] {
            #expect(EquationDetector.mathKind(text) == .strong, "\(text)")
        }
        for text in ["where P is precipitation", "The value = 5 apples here", "Chapter 2", "in turn, starting with evaporation"] {
            #expect(EquationDetector.mathKind(text) == nil, "\(text)")
        }
        #expect(EquationDetector.isEquationNumber("(2.1)") && !EquationDetector.isEquationNumber("(see below)"))
    }

    @Test("Camera and scanner file names don't make titles")
    func genericNames() {
        for name in ["IMG_2041", "Scan 2024-03-01", "PXL_20240301_101112", "Screenshot 2024-01-02 at 10.11.12", "DSC0042", "scan"] {
            #expect(PageScanReader.isGenericName(name), "\(name)")
        }
        for name in ["Chapter 3", "Rivers", "Biology notes"] {
            #expect(!PageScanReader.isGenericName(name), "\(name)")
        }
    }

    @Test("A photographed rectangle's proportions are recovered from its corners")
    func aspectRatio() {
        let frame = CGSize(width: 2000, height: 2600)
        for (tilt, turn, roll) in [(24.0, -9.0, 3.0), (35.0, 12.0, -6.0), (5.0, 2.0, 1.0)] {
            let corners = ScanFixture.projectedCorners(of: ScanFixture.pageSize, in: frame, tilt: tilt, turn: turn, roll: roll)
            let ratio = PerspectiveCorrector.aspectRatio(of: corners, imageSize: frame)
            #expect(abs(ratio / (1700.0 / 2200.0) - 1) < 0.03, "\(tilt), \(turn), \(roll): \(ratio)")
        }
    }

    @Test("Running heads match despite a misread letter")
    func similarKeys() {
        #expect(PageScanReader.similar("understanding earth science", "understanding earth sciencc"))
        #expect(!PageScanReader.similar("chapter one", "a river changes"))
        #expect(!PageScanReader.similar("abc", "abd"))
    }
}
