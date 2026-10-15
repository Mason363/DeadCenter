import Foundation

/// Where an EPUB's files come from: a zipped `.epub`, or an unpacked package directory
/// (Apple Books stores books that way).
protocol EPUBContainer {
    func data(at path: String) -> Data?
}

extension ZipPackage: EPUBContainer {}

struct DirectoryContainer: EPUBContainer {
    let root: URL

    func data(at path: String) -> Data? {
        let url = root.appendingPathComponent(path)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// The package document (OPF): metadata, manifest, spine, and table of contents (EPUB 2 and 3).
struct EPUBPackage {
    struct TOCEntry {
        var title: String
        var path: String
        var fragment: String?
    }

    private struct ManifestItem {
        var id: String
        var path: String
        var mediaType: String
        var properties: [Substring]
    }

    var title: String?
    var spine: [String] = []
    var coverPath: String?
    var tableOfContents: [TOCEntry] = []

    init(container: some EPUBContainer) throws {
        guard let opfPath = Self.packagePath(in: container), let opfData = container.data(at: opfPath) else {
            throw IngestError.unreadable("the book's package file is missing.")
        }
        try Self.checkForDRM(in: container)
        let opf = HTMLParser.parse(TextDecoding.decode(opfData), xmlMode: true)
        let baseDirectory = PackagePath.directory(of: opfPath)

        title = Self.mainTitle(in: opf)

        var items: [ManifestItem] = []
        for element in opf.all(where: { $0.localName == "item" }) {
            guard let id = element.attribute("id"), let href = element.attribute("href"),
                  let path = PackagePath.resolve(href, against: baseDirectory) else { continue }
            items.append(ManifestItem(id: id, path: path, mediaType: element.attribute("media-type")?.lowercased() ?? "",
                              properties: (element.attribute("properties") ?? "").split(separator: " ")))
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func isDocument(_ item: ManifestItem) -> Bool {
            item.mediaType.contains("html") || ["xhtml", "html", "htm"].contains((item.path as NSString).pathExtension.lowercased())
        }

        let spineElement = opf.first { $0.localName == "spine" }
        for ref in spineElement?.elementChildren.filter({ $0.localName == "itemref" }) ?? [] {
            guard ref.attribute("linear")?.lowercased() != "no", let id = ref.attribute("idref"),
                  let item = byID[id], isDocument(item), !item.properties.contains("nav") else { continue }
            spine.append(item.path)
        }
        if spine.isEmpty {
            spine = items.filter { isDocument($0) && !$0.properties.contains("nav") }.map(\.path)
        }

        let coverMeta = opf.all { $0.localName == "meta" && $0.attribute("name")?.lowercased() == "cover" }.first?.attribute("content")
        let cover = items.first { $0.properties.contains("cover-image") }
            ?? coverMeta.flatMap { byID[$0] }
            ?? items.first { $0.mediaType.hasPrefix("image/") && ($0.id.lowercased().contains("cover") || $0.path.lowercased().contains("cover")) }
        coverPath = cover.flatMap { $0.mediaType.hasPrefix("image/") ? $0.path : nil }
            ?? coverMeta.flatMap { PackagePath.resolve($0, against: baseDirectory) }.flatMap { path in
                items.contains { $0.path == path && $0.mediaType.hasPrefix("image/") } ? path : nil
            }

        if let nav = items.first(where: { $0.properties.contains("nav") }), let data = container.data(at: nav.path) {
            tableOfContents = EPUBTableOfContents.fromNav(data, path: nav.path)
        }
        if tableOfContents.isEmpty {
            let ncxID = spineElement?.attribute("toc")
            let ncx = ncxID.flatMap { byID[$0] } ?? items.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncx, let data = container.data(at: ncx.path) {
                tableOfContents = EPUBTableOfContents.fromNCX(data, path: ncx.path)
            }
        }
    }

    private static func packagePath(in container: some EPUBContainer) -> String? {
        if let data = container.data(at: "META-INF/container.xml") {
            let root = HTMLParser.parse(TextDecoding.decode(data), xmlMode: true)
            let rootfiles = root.all { $0.localName == "rootfile" }
            let preferred = rootfiles.first { $0.attribute("media-type")?.contains("oebps-package") == true } ?? rootfiles.first
            if let path = preferred?.attribute("full-path").flatMap({ PackagePath.resolve($0, against: "") }) { return path }
        }
        if let zip = container as? ZipPackage { return zip.paths.sorted().first { $0.lowercased().hasSuffix(".opf") } }
        return nil
    }

    /// The `dc:title` marked as main (EPUB 3 `title-type` refinement), else the first.
    private static func mainTitle(in opf: HTMLElement) -> String? {
        guard let metadata = opf.first(where: { $0.localName == "metadata" }) else { return nil }
        let titles = metadata.all { $0.localName == "title" }
        let mainIDs = metadata.all {
            $0.localName == "meta" && $0.attribute("property") == "title-type"
                && $0.textContent.trimmingCharacters(in: .whitespacesAndNewlines) == "main"
        }.compactMap { $0.attribute("refines")?.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
        let main = titles.first { $0.attribute("id").map(mainIDs.contains) ?? false } ?? titles.first
        let text = main.map { TextNormalizer.clean($0.textContent) }
        return text?.isEmpty == false ? text : nil
    }

    /// Font obfuscation is fine; encrypted content documents mean DRM.
    private static func checkForDRM(in container: some EPUBContainer) throws {
        guard let data = container.data(at: "META-INF/encryption.xml") else { return }
        let root = HTMLParser.parse(TextDecoding.decode(data), xmlMode: true)
        let fontAlgorithms = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        for encrypted in root.all(where: { $0.localName == "encrypteddata" }) {
            let algorithm = encrypted.first { $0.localName == "encryptionmethod" }?.attribute("algorithm") ?? ""
            let uri = encrypted.first { $0.localName == "cipherreference" }?.attribute("uri")?.lowercased() ?? ""
            let isFont = [".otf", ".ttf", ".woff", ".woff2"].contains { uri.hasSuffix($0) }
            if !fontAlgorithms.contains(algorithm), !isFont {
                throw IngestError.unreadable("this book is protected by DRM.")
            }
        }
    }
}

enum EPUBTableOfContents {
    private static let maximumDepth = 3

    /// EPUB 3 navigation document: the `<nav epub:type="toc">` list.
    static func fromNav(_ data: Data, path: String) -> [EPUBPackage.TOCEntry] {
        let root = HTMLParser.parse(TextDecoding.decodeHTML(data))
        let navs = root.all { $0.localName == "nav" }
        let toc = navs.first { ($0.attribute("epub:type") ?? $0.attribute(localName: "type") ?? "").contains("toc") || $0.attribute("role") == "doc-toc" }
            ?? navs.first
        guard let list = toc?.first(where: { $0.localName == "ol" || $0.localName == "ul" }) else { return [] }
        var entries: [EPUBPackage.TOCEntry] = []
        collectNav(list, depth: 0, directory: PackagePath.directory(of: path), into: &entries)
        return entries
    }

    private static func collectNav(_ list: HTMLElement, depth: Int, directory: String, into entries: inout [EPUBPackage.TOCEntry]) {
        guard depth < maximumDepth else { return }
        for item in list.elementChildren where item.localName == "li" {
            if let link = item.elementChildren.first(where: { $0.localName == "a" }) ?? item.first(where: { $0.localName == "a" }),
               let href = link.attribute("href"), let target = PackagePath.resolve(href, against: directory) {
                let title = TextNormalizer.clean(link.textContent)
                if !title.isEmpty { entries.append(.init(title: title, path: target, fragment: PackagePath.fragment(of: href))) }
            }
            for sublist in item.elementChildren where sublist.localName == "ol" || sublist.localName == "ul" {
                collectNav(sublist, depth: depth + 1, directory: directory, into: &entries)
            }
        }
    }

    /// EPUB 2 NCX: nested `navPoint`s.
    static func fromNCX(_ data: Data, path: String) -> [EPUBPackage.TOCEntry] {
        let root = HTMLParser.parse(TextDecoding.decode(data), xmlMode: true)
        guard let map = root.first(where: { $0.localName == "navmap" }) else { return [] }
        var entries: [EPUBPackage.TOCEntry] = []
        collectNCX(map, depth: 0, directory: PackagePath.directory(of: path), into: &entries)
        return entries
    }

    private static func collectNCX(_ parent: HTMLElement, depth: Int, directory: String, into entries: inout [EPUBPackage.TOCEntry]) {
        guard depth < maximumDepth else { return }
        for point in parent.elementChildren where point.localName == "navpoint" {
            let label = point.elementChildren.first { $0.localName == "navlabel" }.map { TextNormalizer.clean($0.textContent) } ?? ""
            if let src = point.elementChildren.first(where: { $0.localName == "content" })?.attribute("src"),
               let target = PackagePath.resolve(src, against: directory), !label.isEmpty {
                entries.append(.init(title: label, path: target, fragment: PackagePath.fragment(of: src)))
            }
            collectNCX(point, depth: depth + 1, directory: directory, into: &entries)
        }
    }
}
