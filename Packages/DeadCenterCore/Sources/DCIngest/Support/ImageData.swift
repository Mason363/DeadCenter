import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import DCModel

/// ImageIO helpers: probing, decoding, and PNG and JPEG encoding.
enum ImageData {
    /// Images smaller than this on either side are decorations, spacers, or tracking pixels.
    static let minimumSide = 48

    /// Pixel dimensions, or nil if ImageIO can't decode the data.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// An image asset for encoded bytes, or nil if they don't decode or are too small to matter.
    static func asset(_ data: Data, caption: String? = nil, minimumSide: Int = minimumSide) -> ImageAsset? {
        guard let size = pixelSize(of: data), size.width >= minimumSide, size.height >= minimumSide else { return nil }
        return ImageAsset(source: .data(data), pixelWidth: size.width, pixelHeight: size.height, caption: caption)
    }

    /// Decodes the first frame, downsampled so neither side exceeds `maxPixelSize`, honoring EXIF orientation.
    static func cgImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func cgImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return cgImage(from: source, maxPixelSize: maxPixelSize)
    }

    static func cgImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return cgImage(from: source, maxPixelSize: maxPixelSize)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// A white-backed RGB bitmap context, used to render PDF pages and regions.
    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        return ctx
    }
}
