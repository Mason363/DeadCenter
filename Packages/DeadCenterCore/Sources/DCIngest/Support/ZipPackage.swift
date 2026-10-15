import Foundation
import ZIPFoundation

/// Read access to the parts of a ZIP-based document (EPUB, DOCX), indexed once by path.
final class ZipPackage {
    private let archive: Archive
    private var entries: [String: Entry] = [:]
    private var caseInsensitive: [String: Entry] = [:]

    /// Parts larger than this are ignored rather than inflated into memory.
    private static let maximumPartSize: UInt64 = 300_000_000

    init(url: URL) throws {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw IngestError.unreadable("the file isn't a valid archive.")
        }
        for entry in archive where entry.type == .file {
            entries[entry.path] = entries[entry.path] ?? entry
            caseInsensitive[entry.path.lowercased()] = caseInsensitive[entry.path.lowercased()] ?? entry
        }
    }

    var paths: [String] { Array(entries.keys) }

    func contains(_ path: String) -> Bool {
        entries[path] != nil || caseInsensitive[path.lowercased()] != nil
    }

    func data(at path: String) -> Data? {
        guard let entry = entries[path] ?? caseInsensitive[path.lowercased()],
              entry.uncompressedSize <= Self.maximumPartSize else { return nil }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        } catch {
            return nil
        }
        return data
    }
}

/// Paths inside a package: resolving relative references the way a browser would.
enum PackagePath {
    /// The directory part of a path ("OEBPS/text/ch1.xhtml" → "OEBPS/text").
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Resolves `reference` (percent-encoded, possibly with `../` and a fragment) against `directory`.
    /// Returns nil for references that leave the package (other schemes).
    static func resolve(_ reference: String, against directory: String) -> String? {
        var ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = ref.firstIndex(of: "#") { ref = String(ref[..<hash]) }
        if let query = ref.firstIndex(of: "?") { ref = String(ref[..<query]) }
        guard !ref.isEmpty else { return nil }
        if let colon = ref.firstIndex(of: ":"), ref[..<colon].allSatisfy({ $0.isLetter }), ref.distance(from: ref.startIndex, to: colon) > 1 {
            return nil
        }
        ref = ref.removingPercentEncoding ?? ref
        var components: [Substring] = ref.hasPrefix("/") ? [] : directory.split(separator: "/")
        for part in ref.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(part)
            }
        }
        return components.joined(separator: "/")
    }

    /// The fragment of a reference, percent-decoded.
    static func fragment(of reference: String) -> String? {
        guard let hash = reference.firstIndex(of: "#") else { return nil }
        let fragment = String(reference[reference.index(after: hash)...])
        return fragment.isEmpty ? nil : (fragment.removingPercentEncoding ?? fragment)
    }
}
