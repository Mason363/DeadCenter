import Foundation
import DCModel

/// Word `.docx`, read from its WordprocessingML parts.
///
/// AppKit's Office Open XML importer drops images and ignores heading styles unless the
/// style sheet happens to change the font, so the document is walked directly: paragraph
/// styles and outline levels give headings, relationships give images, tables give cells.
enum DOCXReader {
    static func read(url: URL, into emitter: BlockEmitter) throws {
        let package = try ZipPackage(url: url)
        guard let documentData = package.data(at: "word/document.xml") else {
            try RichTextReader.read(url: url, type: .officeOpenXML, into: emitter)
            return
        }
        let title = package.data(at: "docProps/core.xml").flatMap { data in
            HTMLParser.parse(TextDecoding.decode(data), xmlMode: true).first { $0.localName == "title" }?.textContent
        }
        emitter.title(title.flatMap { $0.isBlank ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent)

        let styles = package.data(at: "word/styles.xml").map(DOCXStyles.init) ?? DOCXStyles()
        let relationships = package.data(at: "word/_rels/document.xml.rels").map(relationshipTargets) ?? [:]
        let document = HTMLParser.parse(TextDecoding.decode(documentData), xmlMode: true)
        try Task.checkCancellation()
        guard let body = document.first(where: { $0.localName == "body" }) else { throw IngestError.empty }

        var converter = DOCXConverter(package: package, styles: styles, relationships: relationships)
        converter.visitBlocks(in: body)
        emitter.emit(converter.blocks)
        emitter.progress(1)
    }

    private static func relationshipTargets(_ data: Data) -> [String: String] {
        var targets: [String: String] = [:]
        let root = HTMLParser.parse(TextDecoding.decode(data), xmlMode: true)
        for rel in root.all(where: { $0.localName == "relationship" }) {
            guard let id = rel.attribute("id"), let target = rel.attribute("target"),
                  rel.attribute("targetmode")?.lowercased() != "external" else { continue }
            targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : PackagePath.resolve(target, against: "word")
        }
        return targets
    }
}

/// Paragraph style names and outline levels from `styles.xml`.
private struct DOCXStyles {
    private var names: [String: String] = [:]
    private var outlineLevels: [String: Int] = [:]
    private var basedOn: [String: String] = [:]

    init() {}

    init(_ data: Data) {
        let root = HTMLParser.parse(TextDecoding.decode(data), xmlMode: true)
        for style in root.all(where: { $0.localName == "style" }) {
            guard let id = style.attribute(localName: "styleid") else { continue }
            for child in style.elementChildren {
                switch child.localName {
                case "name": names[id] = child.attribute(localName: "val")?.lowercased()
                case "basedon": basedOn[id] = child.attribute(localName: "val")
                case "ppr":
                    if let level = child.first(where: { $0.localName == "outlinelvl" })?.attribute(localName: "val").flatMap(Int.init) {
                        outlineLevels[id] = level
                    }
                default: break
                }
            }
        }
    }

    /// Heading level for a paragraph style, following `basedOn` a few levels.
    func headingLevel(for styleID: String) -> Int? {
        var id: String? = styleID
        for _ in 0..<4 {
            guard let current = id else { return nil }
            let name = names[current] ?? current.lowercased()
            if name == "title" { return 1 }
            if name == "subtitle" { return 2 }
            for prefix in ["heading ", "heading"] where name.hasPrefix(prefix) {
                if let level = Int(name.dropFirst(prefix.count)), (1...9).contains(level) { return min(level, 6) }
            }
            if let outline = outlineLevels[current], outline < 9 { return min(outline + 1, 6) }
            id = basedOn[current]
        }
        return nil
    }

    func isTableOfContents(_ styleID: String) -> Bool {
        let name = names[styleID] ?? styleID.lowercased()
        return name.hasPrefix("toc") || name.hasPrefix("table of contents")
    }
}

private struct DOCXConverter {
    let package: ZipPackage
    let styles: DOCXStyles
    let relationships: [String: String]
    private(set) var blocks: [Block] = []

    init(package: ZipPackage, styles: DOCXStyles, relationships: [String: String]) {
        self.package = package
        self.styles = styles
        self.relationships = relationships
    }

    mutating func visitBlocks(in container: HTMLElement) {
        for child in container.elementChildren {
            switch child.localName {
            case "p":
                paragraph(child)
            case "tbl":
                for row in child.elementChildren where row.localName == "tr" {
                    for cell in row.elementChildren where cell.localName == "tc" { visitBlocks(in: cell) }
                }
            case "sdt":
                let gallery = child.first { $0.localName == "docpartgallery" }?.attribute(localName: "val")?.lowercased() ?? ""
                if gallery.contains("table of contents") { continue }
                if let content = child.elementChildren.first(where: { $0.localName == "sdtcontent" }) { visitBlocks(in: content) }
            case "customxml", "ins", "moveto", "smarttag", "sdtcontent":
                visitBlocks(in: child)
            default:
                continue
            }
        }
    }

    private mutating func paragraph(_ p: HTMLElement) {
        let properties = p.elementChildren.first { $0.localName == "ppr" }
        let styleID = properties?.elementChildren.first { $0.localName == "pstyle" }?.attribute(localName: "val")
        if let styleID, styles.isTableOfContents(styleID) { return }

        var content = InlineContent()
        collect(p, into: &content)

        var level = styleID.flatMap(styles.headingLevel(for:))
        if level == nil, let outline = properties?.first(where: { $0.localName == "outlinelvl" })?.attribute(localName: "val").flatMap(Int.init), outline < 9 {
            level = min(outline + 1, 6)
        }
        if !content.text.isBlank {
            if let level, content.text.count <= 300 {
                blocks.append(.heading(content.text, level: level))
            } else {
                blocks.append(.paragraph(content.text))
            }
        }
        blocks.append(contentsOf: content.images.map(Block.image))
        for box in content.textBoxes { visitBlocks(in: box) }
    }

    private struct InlineContent {
        var text = ""
        var images: [ImageAsset] = []
        var textBoxes: [HTMLElement] = []
    }

    private func collect(_ element: HTMLElement, into content: inout InlineContent) {
        for child in element.elementChildren {
            switch child.localName {
            case "t": content.text += child.textContent
            case "tab", "ptab", "br", "cr": content.text += " "
            case "nobreakhyphen": content.text += "-"
            case "drawing":
                content.images.append(contentsOf: drawingImages(child))
                content.textBoxes.append(contentsOf: child.all { $0.localName == "txbxcontent" })
            case "pict", "object":
                for data in child.all(where: { $0.localName == "imagedata" }) {
                    if let id = data.attribute(localName: "id"), let asset = image(relationship: id, caption: data.attribute(localName: "title")) {
                        content.images.append(asset)
                    }
                }
            case "txbxcontent": content.textBoxes.append(child)
            case "alternatecontent":
                if let choice = child.elementChildren.first(where: { $0.localName == "choice" }) { collect(choice, into: &content) }
            case "ppr", "rpr", "softhyphen", "sym", "deltext", "instrtext", "del", "movefrom", "fldchar",
                 "footnotereference", "endnotereference", "commentreference", "annotationref", "lastrenderedpagebreak":
                continue
            default:
                collect(child, into: &content)
            }
        }
    }

    private func drawingImages(_ drawing: HTMLElement) -> [ImageAsset] {
        let properties = drawing.first { $0.localName == "docpr" }
        let caption = properties?.attribute("descr") ?? properties?.attribute("title")
        return drawing.all { $0.localName == "blip" }.compactMap { blip in
            blip.attribute(localName: "embed").flatMap { image(relationship: $0, caption: caption) }
        }
    }

    private func image(relationship id: String, caption: String?) -> ImageAsset? {
        guard let path = relationships[id], let data = package.data(at: path) else { return nil }
        return ImageData.asset(data, caption: caption)
    }
}
