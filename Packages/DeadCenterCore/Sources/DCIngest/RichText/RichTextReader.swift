import AppKit
import DCModel

/// RTF, RTFD, Word 97 (.doc), and OpenDocument text via AppKit's attributed-string readers.
///
/// These readers don't involve WebKit and are safe off the main thread. The document type is
/// always passed explicitly so AppKit never falls back to its (main-thread-only) HTML importer.
enum RichTextReader {
    static func read(url: URL, type: NSAttributedString.DocumentType, into emitter: BlockEmitter) throws {
        var attributes: NSDictionary?
        let string: NSAttributedString
        do {
            string = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: &attributes)
        } catch {
            throw IngestError.unreadable("the document couldn't be opened.")
        }
        emitter.title(documentTitle(attributes) ?? url.deletingPathExtension().lastPathComponent)
        try emit(string, into: emitter)
    }

    /// RTF (or RTFD) data from the pasteboard.
    static func read(data: Data, into emitter: BlockEmitter) throws {
        var attributes: NSDictionary?
        for type in [NSAttributedString.DocumentType.rtf, .rtfd] {
            if let string = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: &attributes) {
                emitter.title(documentTitle(attributes) ?? TextNormalizer.titleGuess(from: string.string))
                try emit(string, into: emitter)
                return
            }
        }
        throw IngestError.unreadable("the rich text is damaged.")
    }

    private static func documentTitle(_ attributes: NSDictionary?) -> String? {
        guard let title = attributes?[NSAttributedString.DocumentAttributeKey.title] as? String, !title.isBlank else { return nil }
        return title
    }

    static func emit(_ string: NSAttributedString, into emitter: BlockEmitter) throws {
        let analyzer = RichTextAnalyzer(string)
        let text = string.string as NSString
        var ranges: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        for (i, range) in ranges.enumerated() {
            if i.isMultiple(of: 200) {
                try Task.checkCancellation()
                emitter.progress(Double(i) / Double(max(ranges.count, 1)))
            }
            emitter.emit(analyzer.blocks(in: range))
        }
        emitter.progress(1)
    }
}

/// Classifies paragraphs of an attributed string: headings by size and weight, list items, attachments.
private struct RichTextAnalyzer {
    let string: NSAttributedString
    let characters: NSString
    let bodySize: CGFloat
    let bodyIsBold: Bool

    init(_ string: NSAttributedString) {
        self.string = string
        self.characters = string.string as NSString
        var weights: [CGFloat: Int] = [:]
        var boldChars = 0
        var total = 0
        string.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            weights[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
            if Self.isBold(font) { boldChars += range.length }
            total += range.length
        }
        bodySize = weights.max { $0.value < $1.value }?.key ?? 12
        bodyIsBold = total > 0 && boldChars * 2 > total
    }

    func blocks(in range: NSRange) -> [Block] {
        var blocks: [Block] = []
        var text = ""
        var maxSize: CGFloat = 0
        var allBold = true
        var headerLevel = 0
        var isListItem = false

        string.enumerateAttributes(in: range) { attributes, run, _ in
            let fragment = characters.substring(with: run)
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if let asset = Self.image(from: attachment) {
                    if !text.isBlank { blocks.append(.paragraph(text)); text = "" }
                    blocks.append(.image(asset))
                }
                let rest = fragment.replacingOccurrences(of: "\u{FFFC}", with: "")
                if !rest.isEmpty { text += rest }
                return
            }
            guard !fragment.isBlank else { text += fragment; return }
            text += fragment
            if let font = attributes[.font] as? NSFont {
                maxSize = max(maxSize, font.pointSize)
                if !Self.isBold(font) { allBold = false }
            } else {
                allBold = false
            }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
                headerLevel = max(headerLevel, style.headerLevel)
                if !style.textLists.isEmpty { isListItem = true }
            }
        }

        var cleaned = TextNormalizer.clean(text)
        guard !cleaned.isEmpty else { return blocks }
        if let marker = TextNormalizer.listMarker(in: cleaned), marker.isSymbol || isListItem {
            cleaned = TextNormalizer.strippingBullet(cleaned)
            isListItem = true
        }
        if let level = headingLevel(text: cleaned, size: maxSize, bold: allBold, headerLevel: headerLevel, isListItem: isListItem) {
            blocks.append(.heading(cleaned, level: level))
        } else {
            blocks.append(.paragraph(cleaned))
        }
        return blocks
    }

    private func headingLevel(text: String, size: CGFloat, bold: Bool, headerLevel: Int, isListItem: Bool) -> Int? {
        if headerLevel > 0 { return headerLevel }
        guard !isListItem, text.count <= 150, size > 0 else { return nil }
        let ratio = size / bodySize
        if ratio >= 1.8 { return 1 }
        if ratio >= 1.4 { return 2 }
        if ratio >= 1.18 { return 3 }
        if bold, !bodyIsBold, ratio >= 0.98, text.count <= 80, !TextNormalizer.endsSentence(text) { return 4 }
        return nil
    }

    private static func isBold(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    private static func image(from attachment: NSTextAttachment) -> ImageAsset? {
        if let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents, let asset = ImageData.asset(data) {
            return asset
        }
        if let image = attachment.image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let png = ImageData.pngData(cg) {
            return ImageData.asset(png)
        }
        return nil
    }
}
