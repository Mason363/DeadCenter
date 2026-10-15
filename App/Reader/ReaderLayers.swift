import AppKit
import QuartzCore
import DCEngine

/// A layer with no implicit animations; everything that moves is animated explicitly.
nonisolated class StillLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

nonisolated final class StillTextLayer: CATextLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

/// Draws the current word with its pivot centered on `pivotX`, and, inside an aside or quote,
/// faint enclosing marks hugging it on both sides.
nonisolated final class WordLayer: StillLayer {
    struct Marks {
        let open: TypesetWord
        let close: TypesetWord
        let gap: CGFloat
    }

    var word: TypesetWord? { didSet { setNeedsDisplay() } }
    var marks: Marks? { didSet { setNeedsDisplay() } }
    var pivotX: CGFloat = 0 { didSet { if pivotX != oldValue { setNeedsDisplay() } } }
    var baseline: CGFloat = 0 { didSet { if baseline != oldValue { setNeedsDisplay() } } }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        guard let word else { return }
        word.draw(in: ctx, pivotAt: pivotX, baseline: baseline)
        guard let marks else { return }
        let left = pivotX - word.pivotCenter
        let right = left + word.width
        marks.open.draw(in: ctx, pivotAt: left - marks.gap - marks.open.width + marks.open.pivotCenter, baseline: baseline)
        marks.close.draw(in: ctx, pivotAt: right + marks.gap + marks.close.pivotCenter, baseline: baseline)
    }
}

/// The paused "ribbon": neighboring words laid out on the reading line around the current word.
///
/// Entries are positioned in strip space, where the anchor word's pivot is at x = 0. The layer
/// is view-sized and draws only what's visible at the current `shift`, so scrubbing never
/// rebuilds anything heavier than a redraw.
nonisolated final class RibbonLayer: StillLayer {
    struct Entry {
        let index: Int
        let text: String
        let pivot: Int
        let word: TypesetWord
        /// Pivot center in strip space.
        let pivotX: CGFloat
        var left: CGFloat { pivotX - word.pivotCenter }
        var right: CGFloat { left + word.width }
    }

    var entries: [Entry] = [] { didSet { setNeedsDisplay() } }
    /// Screen x of strip-space 0, relative to the layer's horizontal center.
    var shift: CGFloat = 0 { didSet { if shift != oldValue { setNeedsDisplay() } } }
    var highlighted: Int = -1 { didSet { if highlighted != oldValue { setNeedsDisplay() } } }
    var baseline: CGFloat = 0
    var wordStyle: WordStyle?

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func screenX(ofPivot entry: Entry) -> CGFloat {
        bounds.midX + entry.pivotX + shift
    }

    /// The entry whose pivot is closest to the center line.
    func centeredEntry() -> Entry? {
        entries.min { abs($0.pivotX + shift) < abs($1.pivotX + shift) }
    }

    func entry(atScreenX x: CGFloat) -> Entry? {
        let stripX = x - bounds.midX - shift
        return entries.first { stripX >= $0.left - 4 && stripX <= $0.right + 4 }
    }

    override func draw(in ctx: CGContext) {
        guard let style = wordStyle else { return }
        let minX = -bounds.midX - shift - 20
        let maxX = bounds.midX - shift + 20
        for entry in entries where entry.right >= minX && entry.left <= maxX {
            let x = bounds.midX + entry.pivotX + shift
            if entry.index == highlighted {
                Typesetter.typeset(entry.text, pivot: entry.pivot, style: style)
                    .draw(in: ctx, pivotAt: x, baseline: baseline)
            } else {
                entry.word.draw(in: ctx, pivotAt: x, baseline: baseline)
            }
        }
    }
}

/// A tiny explicit animation driven by the display link.
struct Tween {
    var from: CGFloat
    var to: CGFloat
    var start: CFTimeInterval
    var duration: CFTimeInterval

    func value(at t: CFTimeInterval) -> CGFloat {
        let p = min(max((t - start) / duration, 0), 1)
        // Ease-out quint: quick to respond, soft to land.
        let eased = 1 - pow(1 - p, 5)
        return from + (to - from) * eased
    }

    func isDone(at t: CFTimeInterval) -> Bool { t >= start + duration }
}
