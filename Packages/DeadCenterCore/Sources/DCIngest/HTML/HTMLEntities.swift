import Foundation

/// Character reference decoding for HTML text and attribute values.
enum HTMLEntities {
    static func decode(_ text: String, inAttribute: Bool = false) -> String {
        guard text.contains("&") else { return text }
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "&", i + 1 < chars.count else {
                out.append(c)
                i += 1
                continue
            }
            if let (scalars, length) = reference(in: chars, at: i, inAttribute: inAttribute) {
                out.append(contentsOf: scalars)
                i += length
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }

    /// Decodes the reference starting at `chars[start]` (an ampersand), returning its scalars and length.
    private static func reference(in chars: [Unicode.Scalar], at start: Int, inAttribute: Bool) -> ([Unicode.Scalar], Int)? {
        var i = start + 1
        if chars[i] == "#" {
            i += 1
            var hex = false
            if i < chars.count, chars[i] == "x" || chars[i] == "X" { hex = true; i += 1 }
            var value: UInt32 = 0
            let digitsStart = i
            while i < chars.count, i - digitsStart < 8, let d = digitValue(chars[i], hex: hex) {
                value = value &* (hex ? 16 : 10) &+ d
                i += 1
            }
            guard i > digitsStart else { return nil }
            if i < chars.count, chars[i] == ";" { i += 1 }
            return ([numericScalar(value)], i - start)
        }
        let nameStart = i
        while i < chars.count, i - nameStart < 32, chars[i].properties.isAlphabetic || ("0"..."9").contains(chars[i]) { i += 1 }
        guard i > nameStart else { return nil }
        let name = String(String.UnicodeScalarView(chars[nameStart..<i]))
        if i < chars.count, chars[i] == ";", let value = named[name] {
            return (Array(value.unicodeScalars), i + 1 - start)
        }
        // Legacy references without a semicolon, only in text (URLs in attributes often contain "&copy=").
        guard !inAttribute else { return nil }
        for legacy in legacyNames where name.hasPrefix(legacy) {
            if let value = named[legacy] { return (Array(value.unicodeScalars), legacy.unicodeScalars.count + 1) }
        }
        return nil
    }

    private static func digitValue(_ c: Unicode.Scalar, hex: Bool) -> UInt32? {
        switch c.value {
        case 0x30...0x39: c.value - 0x30
        case 0x61...0x66 where hex: c.value - 0x61 + 10
        case 0x41...0x46 where hex: c.value - 0x41 + 10
        default: nil
        }
    }

    private static func numericScalar(_ value: UInt32) -> Unicode.Scalar {
        if let mapped = windows1252[value] { return mapped }
        guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
        return scalar
    }

    private static let legacyNames = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    /// HTML numeric references in 0x80–0x9F mean Windows-1252 characters.
    private static let windows1252: [UInt32: Unicode.Scalar] = [
        0x80: "\u{20AC}", 0x82: "\u{201A}", 0x83: "\u{0192}", 0x84: "\u{201E}", 0x85: "\u{2026}", 0x86: "\u{2020}",
        0x87: "\u{2021}", 0x88: "\u{02C6}", 0x89: "\u{2030}", 0x8A: "\u{0160}", 0x8B: "\u{2039}", 0x8C: "\u{0152}",
        0x8E: "\u{017D}", 0x91: "\u{2018}", 0x92: "\u{2019}", 0x93: "\u{201C}", 0x94: "\u{201D}", 0x95: "\u{2022}",
        0x96: "\u{2013}", 0x97: "\u{2014}", 0x98: "\u{02DC}", 0x99: "\u{2122}", 0x9A: "\u{0161}", 0x9B: "\u{203A}",
        0x9C: "\u{0153}", 0x9E: "\u{017E}", 0x9F: "\u{0178}",
    ]

    /// The HTML 4 named references plus common HTML5 additions.
    private static let named: [String: String] = [
        "quot": "\"", "amp": "&", "apos": "'", "lt": "<", "gt": ">", "nbsp": "\u{A0}", "iexcl": "¡", "cent": "¢",
        "pound": "£", "curren": "¤", "yen": "¥", "brvbar": "¦", "sect": "§", "uml": "¨", "copy": "©", "ordf": "ª",
        "laquo": "«", "not": "¬", "shy": "\u{AD}", "reg": "®", "macr": "¯", "deg": "°", "plusmn": "±", "sup2": "²",
        "sup3": "³", "acute": "´", "micro": "µ", "para": "¶", "middot": "·", "cedil": "¸", "sup1": "¹", "ordm": "º",
        "raquo": "»", "frac14": "¼", "frac12": "½", "frac34": "¾", "iquest": "¿", "Agrave": "À", "Aacute": "Á",
        "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È",
        "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "ETH": "Ð",
        "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "times": "×",
        "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý", "THORN": "Þ",
        "szlig": "ß", "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å",
        "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì",
        "iacute": "í", "icirc": "î", "iuml": "ï", "eth": "ð", "ntilde": "ñ", "ograve": "ò", "oacute": "ó",
        "ocirc": "ô", "otilde": "õ", "ouml": "ö", "divide": "÷", "oslash": "ø", "ugrave": "ù", "uacute": "ú",
        "ucirc": "û", "uuml": "ü", "yacute": "ý", "thorn": "þ", "yuml": "ÿ", "OElig": "Œ", "oelig": "œ",
        "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜", "Alpha": "Α", "Beta": "Β",
        "Gamma": "Γ", "Delta": "Δ", "Epsilon": "Ε", "Zeta": "Ζ", "Eta": "Η", "Theta": "Θ", "Iota": "Ι", "Kappa": "Κ",
        "Lambda": "Λ", "Mu": "Μ", "Nu": "Ν", "Xi": "Ξ", "Omicron": "Ο", "Pi": "Π", "Rho": "Ρ", "Sigma": "Σ",
        "Tau": "Τ", "Upsilon": "Υ", "Phi": "Φ", "Chi": "Χ", "Psi": "Ψ", "Omega": "Ω", "alpha": "α", "beta": "β",
        "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "rho": "ρ", "sigmaf": "ς",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "thetasym": "ϑ", "upsih": "ϒ", "piv": "ϖ", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}", "ndash": "–", "mdash": "—",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„", "dagger": "†",
        "Dagger": "‡", "bull": "•", "hellip": "…", "permil": "‰", "prime": "′", "Prime": "″", "lsaquo": "‹",
        "rsaquo": "›", "oline": "‾", "frasl": "⁄", "euro": "€", "image": "ℑ", "weierp": "℘", "real": "ℜ",
        "trade": "™", "alefsym": "ℵ", "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔", "crarr": "↵",
        "lArr": "⇐", "uArr": "⇑", "rArr": "⇒", "dArr": "⇓", "hArr": "⇔", "forall": "∀", "part": "∂", "exist": "∃",
        "empty": "∅", "nabla": "∇", "isin": "∈", "notin": "∉", "ni": "∋", "prod": "∏", "sum": "∑", "minus": "−",
        "lowast": "∗", "radic": "√", "prop": "∝", "infin": "∞", "ang": "∠", "and": "∧", "or": "∨", "cap": "∩",
        "cup": "∪", "int": "∫", "there4": "∴", "sim": "∼", "cong": "≅", "asymp": "≈", "ne": "≠", "equiv": "≡",
        "le": "≤", "ge": "≥", "sub": "⊂", "sup": "⊃", "nsub": "⊄", "sube": "⊆", "supe": "⊇", "oplus": "⊕",
        "otimes": "⊗", "perp": "⊥", "sdot": "⋅", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
        "lang": "⟨", "rang": "⟩", "loz": "◊", "spades": "♠", "clubs": "♣", "hearts": "♥", "diams": "♦",
        "hyphen": "‐", "dash": "‐", "nbhy": "\u{2011}", "ell": "ℓ", "star": "☆", "starf": "★", "check": "✓",
        "cross": "✗", "half": "½", "frac13": "⅓", "frac23": "⅔", "Hat": "^", "grave": "`",
        "lpar": "(", "rpar": ")", "comma": ",", "period": ".", "colon": ":", "semi": ";", "excl": "!",
        "quest": "?", "num": "#", "dollar": "$", "percnt": "%", "ast": "*", "plus": "+", "equals": "=",
        "sol": "/", "bsol": "\\", "lsqb": "[", "rsqb": "]", "lcub": "{", "rcub": "}", "verbar": "|",
        "lowbar": "_", "commat": "@", "NewLine": "\n", "Tab": "\t",
    ]
}
