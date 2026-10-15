import Foundation
import PDFKit

/// Owns a `PDFDocument` and runs work against it on a private serial queue with a time limit.
///
/// PDFKit calls can't be interrupted, so a pathological page could hang ingestion. When a
/// call overruns, the worker abandons that queue (letting the stuck call finish on its own)
/// and reopens the document on a fresh queue, so reading continues with the next page.
final class PDFWorker: @unchecked Sendable {
    private let url: URL
    private var document: PDFDocument
    private var queue: DispatchQueue

    init(url: URL) throws {
        self.url = url
        self.document = try Self.open(url)
        self.queue = Self.makeQueue()
    }

    private static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw IngestError.unreadable("the PDF is damaged or isn't a PDF.")
        }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw IngestError.unreadable("the PDF is password-protected.")
        }
        return document
    }

    private static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "DeadCenter.PDFWorker", qos: .userInitiated)
    }

    /// Runs `body` with the document. Returns nil if it took longer than `timeout` seconds.
    func run<T: Sendable>(timeout: TimeInterval, _ body: @escaping @Sendable (PDFDocument) -> T) throws -> T? {
        let result = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let document = UncheckedSendable(value: self.document)
        queue.async {
            result.set(body(document.value))
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            try Task.checkCancellation()
            if Date() >= deadline {
                self.document = try Self.open(url)
                queue = Self.makeQueue()
                return nil
            }
        }
        return result.value
    }
}
