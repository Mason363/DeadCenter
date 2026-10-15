import Foundation
import Testing
import UniformTypeIdentifiers
import DCModel
@testable import DCIngest

@Suite("Ingestor API")
struct IngestorAPITests {
    @Test("Declares the supported content types")
    func contentTypes() {
        let types = Ingestor.supportedContentTypes
        for type in [UTType.pdf, .epub, .plainText, .rtf, .html, .png, .jpeg, .webArchive] {
            #expect(types.contains(type), "\(type)")
        }
        #expect(types.contains { $0.identifier == "net.daringfireball.markdown" })
        #expect(types.contains { $0.identifier == "org.openxmlformats.wordprocessingml.document" })
    }

    @Test("canOpen judges by extension and type")
    func canOpen() {
        for name in ["a.pdf", "b.epub", "c.md", "d.txt", "e.docx", "f.rtf", "g.html", "h.webarchive", "i.png", "j.HEIC", "k.odt", "l.doc"] {
            #expect(Ingestor.canOpen(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["a.zip", "b.mp3", "c.xlsx", "d.app"] {
            #expect(!Ingestor.canOpen(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        #expect(!Ingestor.canOpen(URL(string: "https://example.com/a.pdf")!))
    }

    @Test("Missing files and unsupported formats produce friendly errors")
    func errors() async throws {
        do {
            _ = try await ingest(.file(URL(fileURLWithPath: "/nonexistent/file.pdf")))
            Issue.record("expected an error")
        } catch let error as IngestError {
            guard case .unreadable = error else { Issue.record("wrong error \(error)"); return }
            #expect(error.localizedDescription.contains("couldn't be found"))
        }

        let dir = TemporaryDirectory()
        let url = try dir.write(Data([0, 1, 2, 3, 0, 0, 7]), to: "song.mp3")
        do {
            _ = try await ingest(.file(url))
            Issue.record("expected an error")
        } catch let error as IngestError {
            guard case .unsupported(let what) = error else { Issue.record("wrong error \(error)"); return }
            #expect(what == "MP3")
        }
    }

    @Test("Empty input reports .empty")
    func empty() async throws {
        await #expect(throws: IngestError.self) { try await ingest(.text("   \n\n  ")) }
        do {
            _ = try await ingest(.text("\u{200B}\u{00AD} \n"))
        } catch let error as IngestError {
            guard case .empty = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test("Files without an extension are sniffed")
    func sniffing() async throws {
        let dir = TemporaryDirectory()
        let url = try dir.write(SamplePDF.make(), to: "no-extension")
        let result = try await ingest(.file(url))
        #expect(result.paragraphs.first == SamplePDF.p1)
    }

    @Test("Web input with a file URL reads the file")
    func webFileURL() async throws {
        let dir = TemporaryDirectory()
        let url = try dir.write("Hello from a file.", to: "note.txt")
        let result = try await ingest(.web(url))
        #expect(result.paragraphs == ["Hello from a file."])
        #expect(result.title == "note")
    }
}
