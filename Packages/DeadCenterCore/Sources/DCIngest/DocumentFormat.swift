import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The file formats ingestion understands.
enum DocumentFormat: CaseIterable {
    case plainText, markdown, latex, rtf, rtfd, doc, docx, odt, html, webArchive, pdf, epub, image

    static let markdownType = UTType("net.daringfireball.markdown") ?? UTType(importedAs: "net.daringfireball.markdown")
    static let docType = UTType("com.microsoft.word.doc") ?? UTType(importedAs: "com.microsoft.word.doc")
    static let docxType = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
    static let odtType = UTType("org.oasis-open.opendocument.text") ?? UTType(importedAs: "org.oasis-open.opendocument.text")
    static let texType = UTType("org.tug.tex") ?? UTType(filenameExtension: "tex", conformingTo: .plainText) ?? .plainText

    static let contentTypes: [UTType] = [
        .plainText, markdownType, texType, .rtf, .rtfd, .flatRTFD, docType, docxType, odtType, .html, .webArchive, .pdf, .epub,
        .png, .jpeg, .heic, .heif, .tiff, .gif, .webP, .bmp,
    ]

    private static let byExtension: [String: DocumentFormat] = [
        "txt": .plainText, "text": .plainText, "log": .plainText,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown, "mkdn": .markdown,
        "mdwn": .markdown, "mdtxt": .markdown, "rmd": .markdown, "tex": .latex, "latex": .latex, "ltx": .latex,
        "rtf": .rtf, "rtfd": .rtfd, "doc": .doc, "docx": .docx, "docm": .docx, "dotx": .docx, "odt": .odt,
        "html": .html, "htm": .html, "xhtml": .html, "xht": .html, "webarchive": .webArchive,
        "pdf": .pdf, "epub": .epub,
        "png": .image, "jpg": .image, "jpeg": .image, "heic": .image, "heif": .image, "tif": .image, "tiff": .image,
        "gif": .image, "webp": .image, "bmp": .image,
    ]

    /// The format suggested by a file's extension or declared type, without reading it.
    static func declared(by url: URL) -> DocumentFormat? {
        let ext = url.pathExtension.lowercased()
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
        if isDirectory {
            return ext == "epub" ? .epub : ext == "rtfd" ? .rtfd : nil
        }
        if let format = byExtension[ext] { return format }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        return format(conformingTo: type)
    }

    static func format(conformingTo type: UTType) -> DocumentFormat? {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .epub) { return .epub }
        if type.conforms(to: .webArchive) { return .webArchive }
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) { return .rtfd }
        if type.conforms(to: .rtf) { return .rtf }
        if type.conforms(to: docxType) { return .docx }
        if type.conforms(to: docType) { return .doc }
        if type.conforms(to: odtType) { return .odt }
        if type.conforms(to: markdownType) { return .markdown }
        if type.identifier == texType.identifier { return .latex }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .plainText) { return .plainText }
        return nil
    }

    static func format(mimeType: String) -> DocumentFormat? {
        let mime = mimeType.lowercased()
        if mime.contains("markdown") { return .markdown }
        if mime.hasPrefix("text/plain") { return .plainText }
        return UTType(mimeType: mime).flatMap(format(conformingTo:))
    }

    /// The format of some bytes, judged by their signature.
    static func sniff(_ data: Data) -> DocumentFormat? {
        let head = [UInt8](data.prefix(1024))
        func starts(with bytes: [UInt8]) -> Bool { head.count >= bytes.count && Array(head.prefix(bytes.count)) == bytes }
        let ascii = String(decoding: head, as: UTF8.self)
        if ascii.contains("%PDF-") { return .pdf }
        if starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            if ascii.contains("mimetypeapplication/epub+zip") { return .epub }
            if ascii.contains("mimetypeapplication/vnd.oasis.opendocument.text") { return .odt }
            if ascii.contains("word/") || ascii.contains("[Content_Types].xml") { return .docx }
            return nil
        }
        if starts(with: Array("{\\rtf".utf8)) { return .rtf }
        if starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return .doc }
        if starts(with: Array("bplist00".utf8)), data.range(of: Data("WebMainResource".utf8)) != nil { return .webArchive }
        let lowered = ascii.lowercased().drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        if lowered.hasPrefix("<!doctype html") || lowered.hasPrefix("<html") || (lowered.hasPrefix("<?xml") && lowered.contains("<html")) {
            return .html
        }
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) != nil,
           CGImageSourceGetCount(source) > 0 {
            return .image
        }
        if starts(with: [0xFF, 0xFE]) || starts(with: [0xFE, 0xFF]) || !head.contains(0) {
            return .plainText
        }
        return nil
    }

    var filenameExtension: String {
        switch self {
        case .plainText: "txt"
        case .markdown: "md"
        case .latex: "tex"
        case .rtf: "rtf"
        case .rtfd: "rtfd"
        case .doc: "doc"
        case .docx: "docx"
        case .odt: "odt"
        case .html: "html"
        case .webArchive: "webarchive"
        case .pdf: "pdf"
        case .epub: "epub"
        case .image: "png"
        }
    }
}
