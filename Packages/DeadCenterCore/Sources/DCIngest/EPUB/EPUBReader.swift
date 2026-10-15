import Foundation
import DCModel

/// EPUB 2 and 3: the spine in order, each chapter through the shared HTML walker, the table of
/// contents as chapter markers (at the anchor they point to), and the cover as the first image.
enum EPUBReader {
    static func read(url: URL, into emitter: BlockEmitter) throws {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let container: any EPUBContainer = isDirectory ? DirectoryContainer(root: url) : try ZipPackage(url: url)
        let book = try EPUBPackage(container: container)
        emitter.title(book.title ?? url.deletingPathExtension().lastPathComponent)

        var seenImages: Set<ImageAsset.Source> = []
        if let coverPath = book.coverPath, let data = container.data(at: coverPath), let cover = ImageData.asset(data) {
            emitter.emit(.image(cover))
            seenImages.insert(.data(data))
        }

        let entriesByPath = Dictionary(grouping: book.tableOfContents, by: \.path)
        for (index, path) in book.spine.enumerated() {
            try Task.checkCancellation()
            defer { emitter.progress(Double(index + 1) / Double(book.spine.count)) }
            guard let data = container.data(at: path) else { continue }
            let document = HTMLParser.parse(TextDecoding.decodeHTML(data))
            let entries = entriesByPath[path] ?? []
            if entries.isEmpty, isTableOfContentsPage(document) { continue }

            let ids = entries.contains { $0.fragment != nil } ? elementIDs(in: document) : []
            var leading: [String] = []
            var anchors: [String: [String]] = [:]
            for entry in entries {
                if let fragment = entry.fragment, ids.contains(fragment) {
                    anchors[fragment, default: []].append(entry.title)
                } else {
                    leading.append(entry.title)
                }
            }

            let resolver = ArchiveImageResolver(container: container, directory: PackagePath.directory(of: path))
            let walker = HTMLBlockWalker(options: .init(resolver: resolver, anchors: anchors, seenImages: seenImages))
            let blocks = walker.walk(document)
            seenImages = walker.seenImages
            emitter.emit(leading.map(Block.chapter))
            emitter.emit(blocks)
            // Entries whose anchor sits in skipped content still mark the chapter list.
            let unreached = walker.unusedAnchors
            emitter.emit(entries.filter { $0.fragment.map(unreached.contains) ?? false }.map { .chapter($0.title) })
        }
    }

    private static func elementIDs(in document: HTMLElement) -> Set<String> {
        Set(document.all { $0.attribute("id") != nil || $0.attribute("name") != nil }.flatMap { [$0.attribute("id"), $0.attribute("name")].compactMap { $0 } })
    }

    /// An HTML table of contents page (EPUB 2 books often have one in the spine): mostly links.
    private static func isTableOfContentsPage(_ document: HTMLElement) -> Bool {
        guard let body = document.first(where: { $0.localName == "body" }) else { return false }
        let headings = body.all { ["h1", "h2", "h3", "h4", "h5", "h6"].contains(String($0.localName)) }
        let total = TextNormalizer.clean(body.textContent).count - headings.reduce(0) { $0 + TextNormalizer.clean($1.textContent).count }
        let links = body.all { $0.localName == "a" && $0.attribute("href").map { !$0.hasPrefix("http") } == true }
        guard total > 0, links.count >= 5 else { return false }
        let linked = links.reduce(0) { $0 + TextNormalizer.clean($1.textContent).count }
        return Double(linked) >= Double(total) * 0.75
    }
}

/// Resolves image references inside an EPUB relative to the chapter that uses them.
struct ArchiveImageResolver: ImageResolver {
    let container: any EPUBContainer
    let directory: String

    func source(for reference: String) -> ImageAsset.Source? {
        let lower = reference.lowercased()
        if lower.hasPrefix("data:") { return DataURI.decode(reference).map { .data($0) } }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: reference).map { .url($0) } }
        guard let path = PackagePath.resolve(reference, against: directory), let data = container.data(at: path) else { return nil }
        return .data(data)
    }
}
