import Foundation
import ZIPFoundation

/// Writes a ZIP archive from in-memory parts (EPUB and DOCX fixtures).
enum ZipFixture {
    /// Parts are written in order; the first part is stored uncompressed (as EPUB requires for `mimetype`).
    static func write(_ parts: [(path: String, data: Data)], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        for (index, part) in parts.enumerated() {
            try archive.addEntry(with: part.path, type: .file, uncompressedSize: Int64(part.data.count),
                                 compressionMethod: index == 0 ? .none : .deflate) { position, size in
                part.data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    static func write(_ parts: [(String, String)], to url: URL) throws {
        try write(parts.map { (path: $0.0, data: Data($0.1.utf8)) }, to: url)
    }
}
