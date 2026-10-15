import CoreGraphics
import Foundation

/// Display equations on a scanned page: short lines centered in their column and made of math
/// rather than words. OCR garbles them, so they're shown as cropped images instead.
///
/// Deliberately conservative: a line needs a relation or a big operator, almost no words, and
/// body text on both sides to be centered against.
enum EquationDetector {
    struct Equation {
        /// The equation's ink, in page space.
        var rect: CGRect
        /// Indices of the fragments it replaces (including an equation number such as "(2.1)").
        var fragments: [Int]
    }

    static func equations(in fragments: [TextLine], grid: InkGrid, bodyHeight: CGFloat) -> [Equation] {
        guard bodyHeight > 0, fragments.count >= 4 else { return [] }
        struct Candidate {
            var members: [Int]
            var rect: CGRect
            var column: ClosedRange<CGFloat>
            var strong: Bool
        }
        var found: [Candidate] = []
        for cluster in clusters(fragments) {
            let members = cluster.filter { !isEquationNumber(fragments[$0].text) }
            guard !members.isEmpty, let kind = mathKind(members.map { fragments[$0].text }.joined(separator: " ")) else { continue }
            let rect = members.map { fragments[$0].rect }.reduce(CGRect.null) { $0.union($1) }
            guard rect.height <= bodyHeight * 4,
                  let column = column(around: rect, among: fragments, excluding: Set(cluster), bodyHeight: bodyHeight),
                  isCentered(rect, in: column)
            else { continue }
            found.append(Candidate(members: members, rect: rect, column: column, strong: kind == .strong))
        }

        // Neighboring centered math lines (a fraction's numerator and denominator) form one equation.
        var groups: [Candidate] = []
        for candidate in found.sorted(by: { $0.rect.maxY > $1.rect.maxY }) {
            if var last = groups.last, last.rect.minY - candidate.rect.maxY <= bodyHeight * 0.8,
               candidate.rect.maxX > last.rect.minX, candidate.rect.minX < last.rect.maxX {
                last.members += candidate.members
                last.rect = last.rect.union(candidate.rect)
                last.strong = last.strong || candidate.strong
                groups[groups.count - 1] = last
            } else {
                groups.append(candidate)
            }
        }

        return groups.filter(\.strong).compactMap { group in
            // An equation number on the same baseline, out toward the column's edge, goes too.
            let width = group.column.upperBound - group.column.lowerBound
            let numbers = fragments.indices.filter { i in
                let r = fragments[i].rect
                return isEquationNumber(fragments[i].text) && r.midY > group.rect.minY && r.midY < group.rect.maxY
                    && r.minX >= group.rect.maxX && r.maxX <= group.column.upperBound + width * 0.08
            }
            let members = Set(group.members + numbers)
            guard let rect = inkRect(around: group.rect, members: members, fragments: fragments, grid: grid, bodyHeight: bodyHeight)
            else { return nil }
            return Equation(rect: rect, fragments: members.sorted())
        }
    }

    // MARK: - Text

    enum MathKind { case strong, weak }

    private static let relations: Set<Character> = ["=", "≈", "≠", "≤", "≥", "<", ">", "∝", "≡", "∑", "∫", "∏", "√", "∂", "∇", "→", "⇒"]
    private static let mathSymbols: Set<Character> = [
        "+", "-", "−", "–", "×", "÷", "±", "∓", "·", "*", "/", "^", "_", "(", ")", "[", "]", "{", "}", "|", "′", "'", "!",
        "∞", "π", "θ", "λ", "μ", "σ", "Σ", "Ω", "α", "β", "γ", "δ", "Δ", "ε", "φ", "ψ", "ω", "ρ", "τ", "∈", "∀", "∃", "²", "³", "½",
    ]
    private static let mathNames: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "log", "exp", "lim", "max", "min", "det", "sup", "inf", "arg", "mod",
        "sinh", "cosh", "tanh", "arcsin", "arccos", "arctan",
    ]

    /// Whether text reads as math: `.strong` with a relation or a big operator, `.weak` for other
    /// math-like fragments (a denominator), nil for anything with real words in it.
    static func mathKind(_ text: String) -> MathKind? {
        guard !text.isEmpty, text.count <= 80 else { return nil }
        let tokens = text.split(separator: " ")
        let words = tokens.filter { token in
            let letters = token.filter(\.isLetter)
            guard letters.count >= 3, token.allSatisfy({ $0.isLetter || ".,;:'’".contains($0) }) else { return false }
            return !mathNames.contains(letters.lowercased())
        }
        guard words.count <= 1, words.count * 4 <= tokens.count else { return nil }
        let visible = text.filter { !$0.isWhitespace }
        let symbolic = visible.filter { $0.isNumber || relations.contains($0) || mathSymbols.contains($0) }
        guard symbolic.count * 5 >= visible.count else { return nil }
        if visible.contains(where: relations.contains) { return .strong }
        return visible.count <= 12 ? .weak : nil
    }

    static func isEquationNumber(_ text: String) -> Bool {
        text.range(of: #"^\(\s*[A-Z]?\d+(?:[.\-–]\d+)*[a-z]?\s*\)$"#, options: .regularExpression) != nil
    }

    // MARK: - Layout

    /// Fragments chained along a shared baseline with small gaps between them (Vision may split
    /// an equation at its operators), each cluster ordered left to right. Text in another
    /// column on the same baseline stays apart.
    private static func clusters(_ fragments: [TextLine]) -> [[Int]] {
        var clusters: [[Int]] = []
        for i in fragments.indices.sorted(by: { fragments[$0].rect.minX < fragments[$1].rect.minX }) {
            let line = fragments[i].rect
            let joined = clusters.indices.first { k in
                guard let last = clusters[k].last.map({ fragments[$0].rect }) else { return false }
                let overlap = min(last.maxY, line.maxY) - max(last.minY, line.minY)
                return overlap > min(last.height, line.height) * 0.5 && line.minX - last.maxX <= max(last.height, line.height) * 3
            }
            if let joined { clusters[joined].append(i) } else { clusters.append([i]) }
        }
        return clusters
    }

    /// The left and right edges of the column of full lines around `rect`.
    private static func column(around rect: CGRect, among fragments: [TextLine], excluding: Set<Int>,
                               bodyHeight: CGFloat) -> ClosedRange<CGFloat>? {
        let around = fragments.indices.filter { i in
            let r = fragments[i].rect
            return !excluding.contains(i) && r.maxX > rect.minX && r.minX < rect.maxX
                && abs(r.midY - rect.midY) <= bodyHeight * 10 && r.height <= bodyHeight * 1.6
        }.map { fragments[$0].rect }
        guard !around.isEmpty else { return nil }
        // The column's measure: the common width of the longer lines, ignoring wider headings and captions.
        let reference = around.map(\.width).sorted()[around.count * 3 / 4]
        let full = around.filter { $0.width >= reference * 0.8 && $0.width <= reference * 1.25 }
        guard full.count >= 2 else { return nil }
        let left = full.map(\.minX).sorted()[full.count / 2]
        let right = full.map(\.maxX).sorted()[full.count / 2]
        return right > left ? left...right : nil
    }

    /// Whether `rect` is indented about equally from both edges of the column.
    private static func isCentered(_ rect: CGRect, in column: ClosedRange<CGFloat>) -> Bool {
        let width = column.upperBound - column.lowerBound
        guard rect.width <= width * 0.75 else { return false }
        let leftIndent = rect.minX - column.lowerBound, rightIndent = column.upperBound - rect.maxX
        return leftIndent >= width * 0.1 && rightIndent >= width * 0.1 && abs(leftIndent - rightIndent) <= width * 0.15
    }

    /// The equation's ink: the text's box grown to take in what OCR left out (radical bars,
    /// limits, fraction rules), without reaching into the lines above and below.
    private static func inkRect(around text: CGRect, members: Set<Int>, fragments: [TextLine], grid: InkGrid,
                                bodyHeight: CGFloat) -> CGRect? {
        var window = text.insetBy(dx: -bodyHeight, dy: -bodyHeight * 0.9)
        let clearance = bodyHeight * 0.15
        for (i, line) in fragments.enumerated() where !members.contains(i) {
            let r = line.rect.insetBy(dx: 0, dy: -clearance)
            guard r.maxX > window.minX, r.minX < window.maxX, r.maxY > window.minY, r.minY < window.maxY else { continue }
            if r.midY > text.maxY {
                window = CGRect(x: window.minX, y: window.minY, width: window.width, height: max(0, r.minY - window.minY))
            } else if r.midY < text.minY {
                window = CGRect(x: window.minX, y: r.maxY, width: window.width, height: max(0, window.maxY - r.maxY))
            }
        }
        guard window.height >= text.height * 0.8 else { return nil }
        let ink = grid.inkBounds(in: window) ?? text
        let pad = bodyHeight * 0.2
        return ink.union(text.intersection(window)).insetBy(dx: -pad, dy: -pad).intersection(window)
    }
}
