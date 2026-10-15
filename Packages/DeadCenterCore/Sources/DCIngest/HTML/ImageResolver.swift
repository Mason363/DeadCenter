import Foundation
import DCModel

/// Turns an image reference found in a document (`src`, `href`) into a loadable source.
protocol ImageResolver {
    func source(for reference: String) -> ImageAsset.Source?
}

/// Resolves against a base URL: `data:` URIs are decoded, local files are read now (while the
/// sandbox still grants access), and remote images stay URLs for lazy loading.
struct URLImageResolver: ImageResolver {
    var baseURL: URL?

    func source(for reference: String) -> ImageAsset.Source? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty, !ref.hasPrefix("#") else { return nil }
        if ref.lowercased().hasPrefix("data:") {
            return DataURI.decode(ref).map { .data($0) }
        }
        guard let url = URL(string: ref, relativeTo: baseURL)?.absoluteURL else { return nil }
        switch url.scheme?.lowercased() {
        case "http", "https":
            return .url(url)
        case "file":
            return Self.localSource(url)
        default:
            return nil
        }
    }

    static func localSource(_ url: URL) -> ImageAsset.Source? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 0, size < 40_000_000, let data = try? Data(contentsOf: url) {
            return .data(data)
        }
        return FileManager.default.fileExists(atPath: url.path) ? .url(url) : nil
    }
}

/// Serves images from a web archive's subresources, falling back to the URL.
struct WebArchiveImageResolver: ImageResolver {
    var base: URLImageResolver
    var resources: [String: Data]

    func source(for reference: String) -> ImageAsset.Source? {
        guard let resolved = base.source(for: reference) else { return nil }
        if case .url(let url) = resolved, let data = resources[url.absoluteString] {
            return .data(data)
        }
        return resolved
    }
}

enum DataURI {
    /// The bytes of an image `data:` URI.
    static func decode(_ uri: String) -> Data? {
        guard let comma = uri.firstIndex(of: ","), uri.count > 5 else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma].lowercased()
        guard header.isEmpty || header.hasPrefix("image/") || header.hasPrefix(";") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        if header.hasSuffix(";base64") {
            let compact = payload.removingPercentEncoding ?? payload
            return Data(base64Encoded: compact, options: .ignoreUnknownCharacters)
        }
        return (payload.removingPercentEncoding ?? payload).data(using: .utf8)
    }
}
