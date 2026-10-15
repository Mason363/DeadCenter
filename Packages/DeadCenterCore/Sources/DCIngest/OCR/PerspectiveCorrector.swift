import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Vision

/// Finds the page in a photo and flattens it. Scans, screenshots, and photos where the page
/// can't be told apart from its surroundings pass through untouched.
final class PerspectiveCorrector {
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// The page cut out of `image` and flattened, or nil to use the image as it is.
    func straightened(_ image: CGImage) -> CGImage? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let page = request.results?.max(by: { $0.confidence < $1.confidence }), page.confidence >= 0.6
        else { return nil }
        let corners = [page.topLeft, page.topRight, page.bottomRight, page.bottomLeft]
        let coverage = Self.area(of: corners)
        guard coverage >= 0.2, coverage <= 0.95, Self.isConvex(corners), !Self.isUpright(corners, image: image),
              standsOut(corners, in: image)
        else { return nil }

        let width = CGFloat(image.width), height = CGFloat(image.height)
        let pixels = corners.map { CGPoint(x: $0.x * width, y: $0.y * height) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cgImage: image)
        filter.topLeft = pixels[0]
        filter.topRight = pixels[1]
        filter.bottomRight = pixels[2]
        filter.bottomLeft = pixels[3]
        guard var output = filter.outputImage else { return nil }

        // The filter sizes its output from the edge lengths it sees, which foreshortening skews;
        // give the page its real proportions, keeping about the same number of pixels.
        let aspect = Self.aspectRatio(of: pixels, imageSize: CGSize(width: width, height: height))
        let area = output.extent.width * output.extent.height
        var target = CGSize(width: (area * aspect).squareRoot(), height: (area / aspect).squareRoot())
        let longest = max(target.width, target.height)
        let limit = CGFloat(PageScanReader.maximumPixelSize)
        if longest > limit { target = CGSize(width: target.width * limit / longest, height: target.height * limit / longest) }
        output = output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / output.extent.width, y: target.height / output.extent.height))
        let extent = CGRect(origin: .zero, size: target).integral
        guard extent.width >= 200, extent.height >= 200 else { return nil }
        return render(output, extent: extent)
    }

    /// The width-to-height ratio of the rectangle photographed with these corners (pixels,
    /// top-left, top-right, bottom-right, bottom-left), by Zhang and He's method for a camera
    /// with square pixels and a centered principal point. Falls back to the longer edges' ratio
    /// when the corners don't pin down a plausible focal length.
    static func aspectRatio(of corners: [CGPoint], imageSize: CGSize) -> CGFloat {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        let edges = max(distance(corners[0], corners[1]), distance(corners[3], corners[2]))
            / max(distance(corners[0], corners[3]), distance(corners[1], corners[2]), 1)

        func h(_ p: CGPoint) -> SIMD3<Double> { SIMD3(Double(p.x), Double(p.y), 1) }
        func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
        let m1 = h(corners[0]), m2 = h(corners[1]), m3 = h(corners[3]), m4 = h(corners[2])
        let d2 = dot(cross(m2, m4), m3), d3 = dot(cross(m3, m4), m2)
        guard abs(d2) > 1e-9, abs(d3) > 1e-9 else { return edges }
        let n2 = dot(cross(m1, m4), m3) / d2 * m2 - m1
        let n3 = dot(cross(m1, m4), m2) / d3 * m3 - m1
        let u0 = Double(imageSize.width) / 2, v0 = Double(imageSize.height) / 2
        guard abs(n2.z) > 1e-12, abs(n3.z) > 1e-12 else { return edges }
        let f2 = -((n2.x * n3.x - (n2.x * n3.z + n2.z * n3.x) * u0 + n2.z * n3.z * u0 * u0)
            + (n2.y * n3.y - (n2.y * n3.z + n2.z * n3.y) * v0 + n2.z * n3.z * v0 * v0)) / (n2.z * n3.z)
        let diagonal = Double(hypot(imageSize.width, imageSize.height))
        guard f2 > 0, f2.squareRoot() > diagonal * 0.3, f2.squareRoot() < diagonal * 5 else { return edges }
        let f = f2.squareRoot()
        func length2(_ n: SIMD3<Double>) -> Double {
            let a = (n.x - u0 * n.z) / f, b = (n.y - v0 * n.z) / f
            return a * a + b * b + n.z * n.z
        }
        let ratio = CGFloat((length2(n2) / length2(n3)).squareRoot())
        // Far from what the edges suggest means the estimate went wrong.
        guard ratio.isFinite, ratio > edges * 0.7, ratio < edges * 1.4 else { return edges }
        return ratio
    }

    /// `image` turned upright for an EXIF-style orientation (the one Vision was given).
    func rotated(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage? {
        let turned = CIImage(cgImage: image).oriented(orientation)
        return render(turned, extent: turned.extent)
    }

    private func render(_ image: CIImage, extent: CGRect) -> CGImage? {
        context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: - Checks

    /// Area of a quadrilateral (shoelace formula), in the units of its corners.
    static func area(of corners: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Whether every turn around the quadrilateral bends the same way.
    static func isConvex(_ corners: [CGPoint]) -> Bool {
        var sign: CGFloat = 0
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count], c = corners[(i + 2) % corners.count]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > 1e-9 else { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }

    /// A quadrilateral whose edges are all within half a degree of the image axes is a region
    /// of a flat scan or screenshot, not a photographed page.
    private static func isUpright(_ corners: [CGPoint], image: CGImage) -> Bool {
        let scaled = corners.map { CGPoint(x: $0.x * CGFloat(image.width), y: $0.y * CGFloat(image.height)) }
        let limit = tan(0.5 * CGFloat.pi / 180)
        for i in scaled.indices {
            let a = scaled[i], b = scaled[(i + 1) % scaled.count]
            let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
            guard min(dx, dy) <= max(dx, dy) * limit else { return false }
        }
        return true
    }

    /// Whether the page differs clearly from what surrounds it, sampled just inside and just
    /// outside its edges on a small grayscale render.
    private func standsOut(_ corners: [CGPoint], in image: CGImage) -> Bool {
        let width = 400
        let height = max(1, Int(CGFloat(image.height) * CGFloat(width) / CGFloat(max(image.width, 1))))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        func luma(_ p: CGPoint) -> Int? {
            let x = Int(p.x * CGFloat(width)), y = Int((1 - p.y) * CGFloat(height))
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            return Int(pixels[y * width + x])
        }
        let center = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        var differences: [Int] = []
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            for step in 1...9 {
                let t = CGFloat(step) / 10
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                let dx = center.x - p.x, dy = center.y - p.y
                let length = max(hypot(dx, dy), 1e-6)
                let offset: CGFloat = 0.025
                let inside = CGPoint(x: p.x + dx / length * offset, y: p.y + dy / length * offset)
                let outside = CGPoint(x: p.x - dx / length * offset, y: p.y - dy / length * offset)
                if let a = luma(inside), let b = luma(outside) { differences.append(abs(a - b)) }
            }
        }
        guard differences.count >= 8 else { return false }
        return differences.sorted()[differences.count / 2] >= 25
    }
}
