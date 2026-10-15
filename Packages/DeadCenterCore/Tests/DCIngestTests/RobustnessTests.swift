import Foundation
import Testing
import DCModel
@testable import DCIngest

@Suite("Robustness")
struct RobustnessTests {
    /// Deterministic pseudo-random bytes.
    private static func noise(_ count: Int, seed: UInt64) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
    }

    @Test("Garbage in any format fails gracefully", arguments: ["pdf", "epub", "docx", "doc", "odt", "rtf", "rtfd", "html", "md", "txt", "png", "webarchive"])
    func garbage(ext: String) async {
        let dir = TemporaryDirectory()
        for (i, data) in [Data(), Self.noise(64, seed: 1), Self.noise(20_000, seed: 2)].enumerated() {
            guard let url = try? dir.write(data, to: "garbage\(i).\(ext)") else { continue }
            do {
                _ = try await ingest(.file(url))
            } catch {
                #expect(error is IngestError, "\(ext) #\(i): \(error)")
            }
        }
    }

    @Test("Truncated documents fail gracefully or read what they can")
    func truncated() async throws {
        let dir = TemporaryDirectory()
        let epub = dir.file("book.epub")
        try EPUBTests.epub3(at: epub)
        let epubData = try Data(contentsOf: epub)
        let pdfData = SamplePDF.make()
        for (name, data) in [("book.epub", epubData), ("doc.pdf", pdfData)] {
            for fraction in [0.1, 0.5, 0.9] {
                let url = try dir.write(data.prefix(Int(Double(data.count) * fraction)), to: "cut-\(fraction)-\(name)")
                do {
                    _ = try await ingest(.file(url))
                } catch {
                    #expect(error is IngestError, "\(name) at \(fraction): \(error)")
                }
            }
        }
    }

    @Test("Pathological HTML: deep nesting, unclosed tags, stray brackets")
    func pathologicalHTML() async throws {
        let deep = String(repeating: "<div><span>", count: 5000) + "Deep text." + String(repeating: "</span></div>", count: 10)
        let result = try await ingest(.html(deep + "<p>After <b>unclosed <i>tags <a href=x>everywhere", baseURL: nil))
        #expect(result.text.contains("Deep text."))
        #expect(result.text.contains("After unclosed tags everywhere"))

        let stray = try await ingest(.html("a < b and c > d, x <3 y, <!-- unterminated comment", baseURL: nil))
        #expect(stray.paragraphs == ["a < b and c > d, x <3 y,"])
    }

    @Test("Markdown with broken syntax still reads")
    func brokenMarkdown() async throws {
        let result = try await ingest(.text("# Title\n\n**unclosed bold and [broken link](\n\n```\nunterminated fence"))
        #expect(result.headings == ["Title"])
        #expect(result.text.contains("unclosed bold"))
    }
}
