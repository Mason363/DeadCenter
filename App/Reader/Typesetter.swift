import AppKit
import CoreText
import DCEngine

/// Fonts and colors for setting one word.
nonisolated struct WordStyle: Equatable {
    var font: NSFont
    var pivotFont: NSFont
    var text: NSColor
    var pivot: NSColor

    func scaled(_ factor: CGFloat) -> WordStyle {
        var s = self
        s.font = font.withSize(font.pointSize * factor)
        s.pivotFont = pivotFont.withSize(pivotFont.pointSize * factor)
        return s
    }
}

/// A word laid out with Core Text, knowing exactly where the center of its pivot glyph is.
nonisolated struct TypesetWord {
    let line: CTLine
    let width: CGFloat
    /// Distance from the line's origin to the horizontal center of the pivot glyph.
    let pivotCenter: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    func draw(in ctx: CGContext, pivotAt x: CGFloat, baseline: CGFloat) {
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x - pivotCenter, y: baseline)
        CTLineDraw(line, ctx)
    }
}

nonisolated enum Typesetter {
    /// Sets `text` with the pivot character at `pivot` (a `Character` index) in the pivot color.
    /// Ligatures are off so the pivot is always its own glyph; kerning is kept.
    static func typeset(_ text: String, pivot: Int, style: WordStyle,
                        textColor: NSColor? = nil, highlight: Bool = true) -> TypesetWord {
        let base = textColor ?? style.text
        let attributed = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): style.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): base.cgColor,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
        ])

        var pivotRange: NSRange?
        if !text.isEmpty {
            let clamped = min(max(pivot, 0), text.count - 1)
            let start = text.index(text.startIndex, offsetBy: clamped)
            let end = text.index(after: start)
            let range = NSRange(start..<end, in: text)
            pivotRange = range
            attributed.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String),
                                    value: style.pivotFont, range: range)
            if highlight {
                attributed.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                        value: style.pivot.cgColor, range: range)
            }
        }

        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        var center = width / 2
        if let r = pivotRange {
            let a = CTLineGetOffsetForStringIndex(line, r.location, nil)
            let b = CTLineGetOffsetForStringIndex(line, r.location + r.length, nil)
            center = (a + b) / 2
            // Right-to-left runs can report the trailing edge first; fall back to the glyph bounds.
            if abs(b - a) < 0.01 { center = a }
        }
        return TypesetWord(line: line, width: width, pivotCenter: center, ascent: ascent, descent: descent)
    }
}
