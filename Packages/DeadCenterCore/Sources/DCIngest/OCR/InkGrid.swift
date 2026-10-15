import CoreGraphics
import Foundation

/// A coarse map of where a page carries ink, built from a small render of it.
///
/// A cell of a few pixels is ink when enough of its pixels differ clearly from the paper,
/// either darker or strongly colored. The paper's brightness is modeled as a smooth surface
/// fitted across the page, so the uneven lighting of a photo doesn't read as ink.
struct InkGrid {
    /// Width of the small render, in pixels.
    static let renderWidth = 1000
    /// Side of a cell, in render pixels.
    static let cellPixels = 6

    let columns: Int
    let rows: Int
    /// Size of the page the grid covers, in page units (the page image's pixels).
    let pageSize: CGSize
    /// Ink cells, row by row from the top.
    let ink: [Bool]

    /// Page units per render pixel.
    private let scale: CGFloat
    private let width: Int
    private let height: Int
    /// Luminance of the render, row by row from the top.
    private let luma: [UInt8]

    init?(image: CGImage) {
        guard image.width > 0, image.height > 0 else { return nil }
        let width = min(Self.renderWidth, image.width)
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded()))
        let cell = Self.cellPixels
        let columns = (width + cell - 1) / cell
        let rows = (height + cell - 1) / cell
        // Brightness at render size, and each cell's average color from a render at one pixel per cell.
        guard let luma = Self.render(image, width: width, height: height, gray: true),
              let colors = Self.render(image, width: columns, height: rows, gray: false)
        else { return nil }

        let paper = PaperModel(luma: luma, width: width, height: height)
        var chroma = [UInt8](repeating: 0, count: columns * rows)
        for k in chroma.indices {
            let r = colors[k * 4], g = colors[k * 4 + 1], b = colors[k * 4 + 2]
            chroma[k] = max(r, g, b) - min(r, g, b)
        }
        let paperChroma = Int(Self.median(of: chroma))

        // Pixels clearly darker than the paper under them, counted per cell.
        var counts = [Int](repeating: 0, count: columns * rows)
        var thresholds = [Int](repeating: 0, count: columns)
        luma.withUnsafeBufferPointer { pixels in
            for r in 0..<rows {
                for c in 0..<columns {
                    let background = paper.brightness(x: (CGFloat(c) + 0.5) * CGFloat(cell) / CGFloat(width),
                                                      y: (CGFloat(r) + 0.5) * CGFloat(cell) / CGFloat(height))
                    thresholds[c] = Int(background) - Int(max(26, background * 0.14))
                }
                for y in (r * cell)..<min((r + 1) * cell, height) {
                    let row = y * width
                    for c in 0..<columns {
                        let limit = thresholds[c]
                        var n = 0
                        for x in (c * cell)..<min((c + 1) * cell, width) where Int(pixels[row + x]) < limit { n += 1 }
                        counts[r * columns + c] += n
                    }
                }
            }
        }
        var ink = [Bool](repeating: false, count: columns * rows)
        for r in 0..<rows {
            let cellHeight = min(cell, height - r * cell)
            for c in 0..<columns {
                let k = r * columns + c
                let cellWidth = min(cell, width - c * cell)
                ink[k] = counts[k] >= max(3, cellWidth * cellHeight / 9) || Int(chroma[k]) - paperChroma > 40
            }
        }

        self.columns = columns
        self.rows = rows
        self.pageSize = CGSize(width: image.width, height: image.height)
        self.ink = ink
        self.scale = CGFloat(image.width) / CGFloat(width)
        self.width = width
        self.height = height
        self.luma = luma
    }

    /// The image drawn at a size, as 8-bit gray or RGBX bytes, rows from the top.
    private static func render(_ image: CGImage, width: Int, height: Int, gray: Bool) -> [UInt8]? {
        let bytesPerPixel = gray ? 1 : 4
        var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * bytesPerPixel, space: space,
                                      bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Fraction of all cells that hold ink.
    var inkFraction: Double {
        Double(ink.lazy.filter { $0 }.count) / Double(max(ink.count, 1))
    }

    // MARK: - Geometry

    /// The cells overlapping a rectangle in page space (origin bottom-left), clamped to the grid.
    func cells(covering rect: CGRect) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        let side = CGFloat(Self.cellPixels) * scale
        let top = pageSize.height - rect.maxY
        let bottom = pageSize.height - rect.minY
        let c0 = max(0, Int((rect.minX / side).rounded(.down)))
        let c1 = min(columns - 1, Int((rect.maxX / side).rounded(.up)) - 1)
        let r0 = max(0, Int((top / side).rounded(.down)))
        let r1 = min(rows - 1, Int((bottom / side).rounded(.up)) - 1)
        guard c0 <= c1, r0 <= r1 else { return nil }
        return (c0...c1, r0...r1)
    }

    /// A block of cells as a rectangle in page space.
    func rect(columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> CGRect {
        let side = CGFloat(Self.cellPixels) * scale
        let minX = CGFloat(columns.lowerBound) * side
        let maxX = min(pageSize.width, CGFloat(columns.upperBound + 1) * side)
        let top = CGFloat(rows.lowerBound) * side
        let bottom = min(pageSize.height, CGFloat(rows.upperBound + 1) * side)
        return CGRect(x: minX, y: pageSize.height - bottom, width: maxX - minX, height: bottom - top)
    }

    /// The bounds of the ink cells inside `rect`, in page space.
    func inkBounds(in rect: CGRect) -> CGRect? {
        guard let range = cells(covering: rect) else { return nil }
        var c0 = Int.max, c1 = Int.min, r0 = Int.max, r1 = Int.min
        for r in range.rows {
            for c in range.columns where ink[r * columns + c] {
                c0 = min(c0, c); c1 = max(c1, c); r0 = min(r0, r); r1 = max(r1, r)
            }
        }
        guard c0 <= c1 else { return nil }
        return self.rect(columns: c0...c1, rows: r0...r1).intersection(rect)
    }

    /// Whether the render is mostly flat color inside `rect` (a drawn diagram rather than a
    /// photo), judged by how often neighboring pixels match.
    func isFlat(_ rect: CGRect) -> Bool {
        let x0 = max(0, Int(rect.minX / scale)), x1 = min(width - 1, Int(rect.maxX / scale))
        let y0 = max(0, Int((pageSize.height - rect.maxY) / scale)), y1 = min(height - 1, Int((pageSize.height - rect.minY) / scale))
        guard x1 > x0, y1 >= y0 else { return false }
        var same = 0, total = 0
        luma.withUnsafeBufferPointer { l in
            for y in y0...y1 {
                for x in x0..<x1 {
                    let i = y * width + x
                    if abs(Int(l[i]) - Int(l[i + 1])) <= 1 { same += 1 }
                    total += 1
                }
            }
        }
        return total > 0 && Double(same) / Double(total) >= 0.85
    }

    fileprivate static func median(of values: [UInt8]) -> UInt8 {
        guard !values.isEmpty else { return 0 }
        var histogram = [Int](repeating: 0, count: 256)
        for v in values { histogram[Int(v)] += 1 }
        var seen = 0
        for (value, n) in histogram.enumerated() {
            seen += n
            if seen * 2 >= values.count { return UInt8(value) }
        }
        return 255
    }
}

/// The brightness of the bare paper across a page: a quadratic surface fitted to the median
/// brightness of tiles, ignoring tiles that are mostly figure or background.
private struct PaperModel {
    private var coefficients: [Double]

    init(luma: [UInt8], width: Int, height: Int) {
        let tile = 40
        var samples: [(x: Double, y: Double, value: Double)] = []
        var histogram = [Int](repeating: 0, count: 256)
        luma.withUnsafeBufferPointer { l in
            for ty in stride(from: 0, to: height, by: tile) {
                for tx in stride(from: 0, to: width, by: tile) {
                    let w = min(tile, width - tx), h = min(tile, height - ty)
                    guard w * h >= tile * tile / 4 else { continue }
                    // Every other pixel each way is plenty for a median.
                    for i in 0..<256 { histogram[i] = 0 }
                    var sampled = 0
                    for y in stride(from: ty, to: ty + h, by: 2) {
                        for x in stride(from: tx, to: tx + w, by: 2) { histogram[Int(l[y * width + x])] += 1 }
                        sampled += (w + 1) / 2
                    }
                    var seen = 0, median = 255
                    for (value, n) in histogram.enumerated() {
                        seen += n
                        if seen * 2 >= sampled { median = value; break }
                    }
                    let cx = (Double(tx) + Double(w) / 2) / Double(width)
                    let cy = (Double(ty) + Double(h) / 2) / Double(height)
                    samples.append((cx, cy, Double(median)))
                }
            }
        }
        let overall = samples.map(\.value).sorted()
        let fallback = overall.isEmpty ? 255 : overall[overall.count / 2]
        coefficients = [fallback, 0, 0, 0, 0, 0]
        guard samples.count >= 12 else { return }

        // Fit, then refit without the tiles far from the surface (figures, the desk around a
        // photographed page). Paper is the brightest thing on the page, so darker outliers go first.
        var inliers = samples.filter { $0.value >= fallback - 40 }
        for _ in 0..<4 {
            guard inliers.count >= 12, let fit = Self.fit(inliers) else { return }
            coefficients = fit
            let residuals = samples.map { $0.value - Self.evaluate(fit, $0.x, $0.y) }
            let spread = Self.median(residuals.map(abs)) * 1.48
            let below = max(12, 2.5 * spread), above = max(18, 3 * spread)
            inliers = zip(samples, residuals).filter { $0.1 >= -below && $0.1 <= above }.map(\.0)
        }
    }

    /// Paper brightness (0…255) at a point given as fractions of the page's width and height from the top-left.
    func brightness(x: CGFloat, y: CGFloat) -> CGFloat {
        CGFloat(min(255, max(20, Self.evaluate(coefficients, Double(x), Double(y)))))
    }

    private static func terms(_ x: Double, _ y: Double) -> [Double] {
        let u = x * 2 - 1, v = y * 2 - 1
        return [1, u, v, u * u, u * v, v * v]
    }

    private static func evaluate(_ c: [Double], _ x: Double, _ y: Double) -> Double {
        zip(c, terms(x, y)).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Least squares through the normal equations, solved by Gaussian elimination.
    private static func fit(_ samples: [(x: Double, y: Double, value: Double)]) -> [Double]? {
        let n = 6
        var a = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for s in samples {
            let t = terms(s.x, s.y)
            for i in 0..<n {
                for j in 0..<n { a[i][j] += t[i] * t[j] }
                a[i][n] += t[i] * s.value
            }
        }
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[pivot][col]) > 1e-9 else { return nil }
            a.swapAt(col, pivot)
            for row in 0..<n where row != col {
                let factor = a[row][col] / a[col][col]
                guard factor != 0 else { continue }
                for k in col...n { a[row][k] -= factor * a[col][k] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
