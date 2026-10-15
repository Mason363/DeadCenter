import CoreGraphics
import Foundation

/// An image XObject drawn on a page, with its placement in page space.
struct PDFImagePlacement: Sendable, Equatable {
    var rect: CGRect
    /// Identifies the image content (dimensions and encoded length) so repeats can be recognized.
    var identity: String

    /// Same image at the same place: logos, letterheads, decorations.
    var repeatKey: String {
        "\(identity)@\(Int((rect.minX / 4).rounded())),\(Int((rect.minY / 4).rounded())),\(Int((rect.width / 4).rounded())),\(Int((rect.height / 4).rounded()))"
    }
}

/// Finds where image XObjects are drawn by scanning the page's content stream, tracking the
/// current transformation matrix through `q`/`Q`/`cm` and following `Do` into form XObjects.
enum PDFImageLocator {
    /// Content streams larger than this are not scanned (vector maps and the like).
    private static let maximumContentLength = 16_000_000

    static func placements(on page: CGPDFPage) -> [PDFImagePlacement] {
        guard contentLength(of: page) < maximumContentLength, let table = CGPDFOperatorTableCreate() else { return [] }
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in ScanState.from(info)?.save() }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in ScanState.from(info)?.restore() }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in ScanState.from(info)?.concatenate(scanner) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in ScanState.from(info)?.drawObject(scanner) }

        let state = ScanState(table: table)
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
        return state.placements
    }

    private static func contentLength(of page: CGPDFPage) -> Int {
        guard let dictionary = page.dictionary else { return 0 }
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &stream), let stream {
            return length(of: stream)
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array else { return 0 }
        var total = 0
        for i in 0..<CGPDFArrayGetCount(array) {
            var part: CGPDFStreamRef?
            if CGPDFArrayGetStream(array, i, &part), let part { total += length(of: part) }
        }
        return total
    }

    fileprivate static func length(of stream: CGPDFStreamRef) -> Int {
        var length: CGPDFInteger = 0
        guard let dictionary = CGPDFStreamGetDictionary(stream), CGPDFDictionaryGetInteger(dictionary, "Length", &length) else { return 0 }
        return length
    }
}

private final class ScanState {
    let table: CGPDFOperatorTableRef
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var placements: [PDFImagePlacement] = []
    var formsInProgress: Set<Int> = []

    init(table: CGPDFOperatorTableRef) {
        self.table = table
    }

    static func from(_ info: UnsafeMutableRawPointer?) -> ScanState? {
        info.map { Unmanaged<ScanState>.fromOpaque($0).takeUnretainedValue() }
    }

    func save() {
        guard stack.count < 256 else { return }
        stack.append(ctm)
    }

    func restore() {
        if let saved = stack.popLast() { ctm = saved }
    }

    func concatenate(_ scanner: CGPDFScannerRef) {
        var values = [CGFloat](repeating: 0, count: 6)
        for k in (0..<6).reversed() {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &v) else { return }
            values[k] = v
        }
        let m = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
        ctm = m.concatenating(ctm)
    }

    func drawObject(_ scanner: CGPDFScannerRef) {
        guard placements.count < 500 else { return }
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { return }
        let content = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }

        switch String(cString: subtype) {
        case "Image":
            var isMask: CGPDFBoolean = 0
            if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &isMask), isMask != 0 { return }
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(dictionary, "Width", &width)
            CGPDFDictionaryGetInteger(dictionary, "Height", &height)
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm).standardized
            guard rect.width.isFinite, rect.height.isFinite else { return }
            placements.append(PDFImagePlacement(rect: rect, identity: "\(width)x\(height)/\(PDFImageLocator.length(of: stream))"))
        case "Form":
            drawForm(stream, dictionary: dictionary, parent: content)
        default:
            return
        }
    }

    private func drawForm(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, parent: CGPDFContentStreamRef) {
        let key = unsafeBitCast(stream, to: Int.self)
        guard formsInProgress.count < 6, !formsInProgress.contains(key) else { return }
        formsInProgress.insert(key)
        defer { formsInProgress.remove(key) }

        var matrix = CGAffineTransform.identity
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
            var v = [CGFloat](repeating: 0, count: 6)
            for i in 0..<6 {
                var n: CGPDFReal = 0
                CGPDFArrayGetNumber(array, i, &n)
                v[i] = n
            }
            matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)

        let form = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
        defer { CGPDFContentStreamRelease(form) }
        let saved = ctm
        let savedDepth = stack.count
        ctm = matrix.concatenating(ctm)
        let scanner = CGPDFScannerCreate(form, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        if stack.count > savedDepth { stack.removeSubrange(savedDepth...) }
        ctm = saved
    }
}
