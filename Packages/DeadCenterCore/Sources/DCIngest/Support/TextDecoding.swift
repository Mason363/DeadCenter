import Foundation

/// Decodes text of unknown encoding: BOMs, declared charsets, strict UTF-8, then statistical detection.
enum TextDecoding {
    static func decode(_ data: Data, declared: String.Encoding? = nil) -> String {
        if let (encoding, bomLength) = bomEncoding(data),
           let text = String(data: data.dropFirst(bomLength), encoding: encoding) {
            return text
        }
        if let declared, let text = String(data: data, encoding: declared) {
            return text
        }
        if let utf16 = bomlessUTF16(data), let text = String(data: data, encoding: utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = detect(data) {
            return text
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Decodes an HTML document, honoring the transport charset, then a `<meta charset>` declaration.
    static func decodeHTML(_ data: Data, transportCharset: String? = nil) -> String {
        if bomEncoding(data) == nil {
            if let name = transportCharset, let encoding = encoding(ianaName: name),
               let text = String(data: data, encoding: encoding) {
                return text
            }
            if let encoding = sniffedCharset(data), let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return decode(data)
    }

    static func encoding(ianaName: String) -> String.Encoding? {
        let name = ianaName.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        guard !name.isEmpty else { return nil }
        // Browsers treat these labels as their supersets.
        let aliased = switch name {
        case "iso-8859-1", "latin1", "us-ascii", "ascii": "windows-1252"
        case "gb2312", "gbk", "x-gbk": "gb18030"
        case "shift-jis", "sjis", "x-sjis": "shift_jis"
        default: name
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(aliased as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// The charset named by an XML declaration or `<meta>` tag in the first few KB.
    static func sniffedCharset(_ data: Data) -> String.Encoding? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        for marker in ["charset=", "encoding="] {
            var searchStart = head.startIndex
            while let range = head.range(of: marker, range: searchStart..<head.endIndex) {
                searchStart = range.upperBound
                var name = head[range.upperBound...].drop { $0 == "\"" || $0 == "'" || $0 == " " }
                name = name.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "." }
                if let encoding = encoding(ianaName: String(name)) {
                    // A document that claims UTF-16 but parsed as ASCII here is really UTF-8.
                    if encoding == .utf16 || encoding == .utf16LittleEndian || encoding == .utf16BigEndian { return .utf8 }
                    return encoding
                }
            }
        }
        return nil
    }

    private static func bomEncoding(_ data: Data) -> (String.Encoding, Int)? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return (.utf8, 3) }
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xFE, b[2] == 0, b[3] == 0 { return (.utf32LittleEndian, 4) }
        if b.count >= 4, b[0] == 0, b[1] == 0, b[2] == 0xFE, b[3] == 0xFF { return (.utf32BigEndian, 4) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return (.utf16LittleEndian, 2) }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return (.utf16BigEndian, 2) }
        return nil
    }

    /// UTF-16 without a BOM shows up as a zero byte in every other position for Latin text.
    private static func bomlessUTF16(_ data: Data) -> String.Encoding? {
        let sample = [UInt8](data.prefix(2048))
        guard sample.count >= 8 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (i, byte) in sample.enumerated() where byte == 0 {
            if i.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = sample.count / 2
        if oddZeros > half * 4 / 10, evenZeros < half / 20 { return .utf16LittleEndian }
        if evenZeros > half * 4 / 10, oddZeros < half / 20 { return .utf16BigEndian }
        return nil
    }

    private static func detect(_ data: Data) -> String? {
        let candidates: [String.Encoding] = [
            .windowsCP1252,
            encoding(ianaName: "gb18030"), encoding(ianaName: "big5"), .shiftJIS, .japaneseEUC,
            encoding(ianaName: "euc-kr"), .windowsCP1251, encoding(ianaName: "koi8-r"), .windowsCP1250,
        ].compactMap { $0 }
        var converted: NSString?
        var lossy: ObjCBool = false
        let raw = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: candidates.map { NSNumber(value: $0.rawValue) },
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy)
        guard raw != 0, let converted, !lossy.boolValue else { return nil }
        return converted as String
    }
}
