import CoreGraphics
import Foundation
import ImageIO
import Testing
import DCModel
@testable import DCIngest

@Suite("PDF")
struct PDFTests {
    @Test("Rebuilds paragraphs, removes running content, and places chapters and figures")
    func samplePDF() async throws {
        let dir = TemporaryDirectory()
        let url = try dir.write(SamplePDF.make(), to: "sample.pdf")
        let result = try await ingest(.file(url))

        #expect(result.title == SamplePDF.title)
        #expect(result.paragraphs == [SamplePDF.p1, SamplePDF.p2, SamplePDF.p3, SamplePDF.p4, SamplePDF.p5, SamplePDF.p6], "\(result.outline)")
        #expect(result.chapters == ["Chapter One", "Chapter Two"])
        #expect(result.headings == ["A Final Section"], "\(result.outline)")
        #expect(!result.text.contains(SamplePDF.header))
        #expect(!result.text.contains("Page 1"))
        #expect(!result.text.contains("exam- ple") && !result.text.contains("exam-ple"))

        // Order: chapter, p1, p2, figure, p3 … chapter two before p5.
        let kinds = result.blocks.map { block -> String in
            switch block {
            case .chapter: "C"
            case .heading: "H"
            case .paragraph: "P"
            case .image: "I"
            }
        }.joined()
        #expect(kinds == "CPPIPPCPHP", "\(result.outline)")

        let figure = try #require(result.images.first)
        #expect(result.images.count == 1)
        let data = try #require(figure.data)
        let size = try #require(ImageData.pixelSize(of: data))
        #expect(abs(size.width - 432) <= 2 && abs(size.height - 324) <= 2)
        // The rendered region is the figure: blue in the middle, red near the corner.
        let center = try #require(pixel(in: data, x: size.width / 2, y: size.height / 2))
        let corner = try #require(pixel(in: data, x: size.width / 10, y: size.height / 10))
        #expect(center.b > 150 && center.r < 100)
        #expect(corner.r > 150 && corner.b < 100)
        #expect(result.progress.last == 1)
    }

    @Test("Starts streaming a 500-page PDF in well under 300 ms")
    func firstBatchIsFast() async throws {
        let dir = TemporaryDirectory()
        let url = try dir.write(SamplePDF.long(pages: 500), to: "long.pdf")
        let start = ContinuousClock.now
        var firstBatch: Duration?
        var paragraphs = 0
        for try await event in Ingestor.ingest(.file(url)) {
            if case .blocks(let blocks) = event {
                firstBatch = firstBatch ?? (ContinuousClock.now - start)
                paragraphs += blocks.count
                if paragraphs > 100 { break }
            }
        }
        let elapsed = try #require(firstBatch)
        #expect(elapsed < .milliseconds(300), "first batch after \(elapsed)")
    }

    @Test("Long documents: page numbers and running header removed throughout")
    func longDocument() async throws {
        let dir = TemporaryDirectory()
        let url = try dir.write(SamplePDF.long(pages: 12), to: "long.pdf")
        let result = try await ingest(.file(url))
        #expect(result.paragraphs.count == 12 * 8, "\(result.outline.prefix(2000))")
        #expect(!result.text.contains("Long Document"))
        #expect(result.paragraphs.allSatisfy { $0.hasPrefix("Reading") || $0.hasPrefix("and") || $0.hasPrefix("while") })
        #expect(result.paragraphs.allSatisfy { $0.hasSuffix(".") })
    }

    @Test("Cancelling the consumer stops the work promptly")
    func cancellation() async throws {
        let dir = TemporaryDirectory()
        let url = try dir.write(SamplePDF.long(pages: 300), to: "long.pdf")
        let consumer = Task {
            var count = 0
            for try await event in Ingestor.ingest(.file(url)) {
                if case .blocks = event { count += 1 }
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        consumer.cancel()
        _ = await consumer.result
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test("OCRs pages without a text layer")
    func scannedPage() async throws {
        let dir = TemporaryDirectory()
        let url = try dir.write(SamplePDF.scanned(), to: "scan.pdf")
        let result = try await ingest(.file(url))
        #expect(result.paragraphs.first == "This first page has a real text layer and reads normally.")
        let ocr = result.paragraphs.dropFirst().joined(separator: " ").lowercased()
        #expect(ocr.contains("optical character recognition"), "\(result.outline)")
        #expect(result.images.isEmpty, "a scanned page is read, not shown")
        #expect(result.title == "scan")
    }

    @Test("Two-column pages read column by column, joining a paragraph across the gutter")
    func twoColumns() async throws {
        let dir = TemporaryDirectory()
        let url = try dir.write(SamplePDF.twoColumns(), to: "columns.pdf")
        let result = try await ingest(.file(url))
        #expect(result.paragraphs == [SamplePDF.columnsFirst, SamplePDF.columnsSecond], "\(result.outline)")
    }

    @Test("Junk metadata titles fall back to the file name")
    func junkTitle() async throws {
        let pdf = PDFFixtureBuilder(title: "Microsoft Word - draft3.docx")
        pdf.beginPage()
        pdf.paragraph(["Just one line of text."])
        pdf.endPage()
        let dir = TemporaryDirectory()
        let url = try dir.write(pdf.finish(), to: "Quarterly Report.pdf")
        let result = try await ingest(.file(url))
        #expect(result.title == "Quarterly Report")
        #expect(result.paragraphs == ["Just one line of text."])
    }

    @Test("Damaged PDFs fail with a friendly error")
    func damaged() async throws {
        let dir = TemporaryDirectory()
        let url = try dir.write(Data("%PDF-1.4 garbage".utf8), to: "broken.pdf")
        await #expect(throws: IngestError.self) { try await ingest(.file(url)) }
    }

    @Test("Page number patterns")
    func pageNumbers() {
        for text in ["12", "- 12 -", "Page 12 of 40", "page 3", "xiv", "[7]", "12 / 40", "第 3 页"] {
            #expect(RunningContent.isPageNumber(text), "\(text)")
        }
        for text in ["mild", "Chapter 12", "1984 was a year", "did"] {
            #expect(!RunningContent.isPageNumber(text), "\(text)")
        }
    }
}

/// RGB of one pixel (top-left origin) in encoded image data.
func pixel(in data: Data, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
    guard let image = ImageData.cgImage(from: data, maxPixelSize: 100_000),
          let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let buffer = ctx.data?.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4) else { return nil }
    let offset = (y * image.width + x) * 4
    return (Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]))
}
