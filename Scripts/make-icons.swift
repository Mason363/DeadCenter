#!/usr/bin/env swift
// Renders every icon Dead Center ships, with CoreGraphics only.
//
//   swift Scripts/make-icons.swift
//
// Motif: a reticle. Two short vertical ticks above and below a red dot, dead center.
// Outputs:
//   App/Resources/Assets.xcassets/AppIcon.appiconset      macOS app icon, 16–1024 px
//   App/Resources/Assets.xcassets/AppIconImage.imageset   the large icon, for use inside the app
//   App/Resources/Assets.xcassets/MenuBarIcon.imageset    18 pt template image, 1x + 2x
//   WebExtension/icons/icon-{16,32,48,96,128}.png         browser extension icons

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("App/Resources/Assets.xcassets")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

enum Palette {
    static let surfaceTop = color(0x28282B)
    static let surfaceBottom = color(0x0B0B0C)
    static let tick = color(0xF2F2F4)
    static let dot = color(0xFF3B30)
    static let dotLight = color(0xFF6A5F)
}

// MARK: - Geometry

/// Apple's continuous-corner ("squircle") rounded rect, the same curve as the macOS icon grid.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    let path = CGMutablePath()
    // Corner offsets along each edge, as fractions of r (PaintCode's measurement of the system curve).
    let a: CGFloat = 1.52866483, b: CGFloat = 1.08849323, c: CGFloat = 0.86840689
    let d: CGFloat = 0.63149399, e: CGFloat = 0.07491100, f: CGFloat = 0.37282392, g: CGFloat = 0.16905199
    let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)

    path.move(to: CGPoint(x: minX + a * r, y: maxY))
    path.addLine(to: CGPoint(x: maxX - a * r, y: maxY))
    path.addCurve(to: CGPoint(x: maxX - d * r, y: maxY - e * r),
                  control1: CGPoint(x: maxX - b * r, y: maxY), control2: CGPoint(x: maxX - c * r, y: maxY))
    path.addCurve(to: CGPoint(x: maxX - e * r, y: maxY - d * r),
                  control1: CGPoint(x: maxX - f * r, y: maxY - g * r), control2: CGPoint(x: maxX - g * r, y: maxY - f * r))
    path.addCurve(to: CGPoint(x: maxX, y: maxY - a * r),
                  control1: CGPoint(x: maxX, y: maxY - c * r), control2: CGPoint(x: maxX, y: maxY - b * r))
    path.addLine(to: CGPoint(x: maxX, y: minY + a * r))
    path.addCurve(to: CGPoint(x: maxX - e * r, y: minY + d * r),
                  control1: CGPoint(x: maxX, y: minY + b * r), control2: CGPoint(x: maxX, y: minY + c * r))
    path.addCurve(to: CGPoint(x: maxX - d * r, y: minY + e * r),
                  control1: CGPoint(x: maxX - g * r, y: minY + f * r), control2: CGPoint(x: maxX - f * r, y: minY + g * r))
    path.addCurve(to: CGPoint(x: maxX - a * r, y: minY),
                  control1: CGPoint(x: maxX - c * r, y: minY), control2: CGPoint(x: maxX - b * r, y: minY))
    path.addLine(to: CGPoint(x: minX + a * r, y: minY))
    path.addCurve(to: CGPoint(x: minX + d * r, y: minY + e * r),
                  control1: CGPoint(x: minX + b * r, y: minY), control2: CGPoint(x: minX + c * r, y: minY))
    path.addCurve(to: CGPoint(x: minX + e * r, y: minY + d * r),
                  control1: CGPoint(x: minX + f * r, y: minY + g * r), control2: CGPoint(x: minX + g * r, y: minY + f * r))
    path.addCurve(to: CGPoint(x: minX, y: minY + a * r),
                  control1: CGPoint(x: minX, y: minY + c * r), control2: CGPoint(x: minX, y: minY + b * r))
    path.addLine(to: CGPoint(x: minX, y: maxY - a * r))
    path.addCurve(to: CGPoint(x: minX + e * r, y: maxY - d * r),
                  control1: CGPoint(x: minX, y: maxY - b * r), control2: CGPoint(x: minX, y: maxY - c * r))
    path.addCurve(to: CGPoint(x: minX + d * r, y: maxY - e * r),
                  control1: CGPoint(x: minX + g * r, y: maxY - f * r), control2: CGPoint(x: minX + f * r, y: maxY - g * r))
    path.addCurve(to: CGPoint(x: minX + a * r, y: maxY),
                  control1: CGPoint(x: minX + c * r, y: maxY), control2: CGPoint(x: minX + b * r, y: maxY))
    path.closeSubpath()
    return path
}

/// The reticle's proportions for a given body size in pixels. Small sizes get heavier marks
/// and pixel-snapped edges so they stay crisp; large sizes use the master proportions.
struct Reticle {
    var tickWidth: CGFloat
    var dotRadius: CGFloat
    var tickInner: CGFloat // distance from center to the tick's near end
    var tickOuter: CGFloat // distance from center to the tick's far end
    var roundCaps: Bool
    var glow: Bool

    init(body b: CGFloat, centerOnPixelEdge: Bool) {
        let p: (w: CGFloat, dot: CGFloat, inner: CGFloat, outer: CGFloat)
        switch b {
        case ..<20: p = (0.155, 0.155, 0.233, 0.390)
        case ..<40: p = (0.078, 0.117, 0.233, 0.390)
        case ..<80: p = (0.045, 0.072, 0.165, 0.330)
        case ..<160: p = (0.038, 0.060, 0.148, 0.322)
        default: p = (26.0 / 824, 48.0 / 824, 120.0 / 824, 268.0 / 824)
        }
        tickWidth = p.w * b
        dotRadius = p.dot * b
        tickInner = p.inner * b
        tickOuter = p.outer * b
        roundCaps = b >= 40
        glow = b >= 160
        guard b < 160 else { return }
        // Snap so vertical edges land on whole pixels: even widths when the center sits on a
        // pixel edge, odd widths when it sits mid-pixel.
        func snap(_ v: CGFloat) -> CGFloat {
            let n = max(1, v.rounded())
            let wantsEven = centerOnPixelEdge
            return (Int(n) % 2 == 0) == wantsEven ? n : (v > n || n == 1 ? n + 1 : n - 1)
        }
        tickWidth = snap(tickWidth)
        dotRadius = snap(dotRadius * 2) / 2
        tickInner = tickInner.rounded()
        tickOuter = tickOuter.rounded()
    }
}

// MARK: - Rendering

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func drawReticle(in ctx: CGContext, center: CGPoint, _ r: Reticle, tick: CGColor, dot: CGColor?, dotLight: CGColor?) {
    for direction: CGFloat in [1, -1] {
        let y0 = center.y + direction * r.tickInner
        let y1 = center.y + direction * r.tickOuter
        let rect = CGRect(x: center.x - r.tickWidth / 2, y: min(y0, y1), width: r.tickWidth, height: abs(y1 - y0))
        let radius = r.roundCaps ? r.tickWidth / 2 : 0
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(tick)
        ctx.fillPath()
    }

    let dotRect = CGRect(x: center.x - r.dotRadius, y: center.y - r.dotRadius, width: r.dotRadius * 2, height: r.dotRadius * 2)
    guard let dot else {
        ctx.setFillColor(tick)
        ctx.fillEllipse(in: dotRect)
        return
    }
    if r.glow {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: r.dotRadius * 1.6, color: dot.copy(alpha: 0.55))
        ctx.setFillColor(dot)
        ctx.fillEllipse(in: dotRect)
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addEllipse(in: dotRect)
    ctx.clip()
    if let dotLight, r.glow {
        // A whisper of light from above, so the dot reads as a jewel rather than a sticker.
        let gradient = CGGradient(colorsSpace: sRGB, colors: [dotLight, dot] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(gradient,
                               startCenter: CGPoint(x: center.x, y: center.y + r.dotRadius * 0.45), startRadius: 0,
                               endCenter: center, endRadius: r.dotRadius * 1.05, options: [.drawsAfterEndLocation])
    } else {
        ctx.setFillColor(dot)
        ctx.fill(dotRect)
    }
    ctx.restoreGState()
}

/// The app icon on a `canvas`-pixel square. `bodyFraction` is the squircle's share of the canvas
/// (824/1024 on Apple's macOS grid); `shadow` adds the grid's drop shadow.
func renderIcon(canvas: Int, bodyFraction: CGFloat = 824.0 / 1024, shadow: Bool = true) -> CGImage {
    let ctx = makeContext(canvas, canvas)
    let c = CGFloat(canvas)
    let body = c * bodyFraction
    let unit = body / 824 // one unit of Apple's 1024 grid, scaled
    let bodyRect = CGRect(x: (c - body) / 2, y: (c - body) / 2, width: body, height: body)
    let squircle = continuousRoundedRect(bodyRect, radius: 185.4 * unit)

    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 22 * unit, color: color(0x000000, 0.32))
        ctx.addPath(squircle)
        ctx.setFillColor(Palette.surfaceBottom)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Surface: near-black with a faint top light.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let surface = CGGradient(colorsSpace: sRGB, colors: [Palette.surfaceTop, Palette.surfaceBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(surface, start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.minY), options: [])
    let sheen = CGGradient(colorsSpace: sRGB, colors: [color(0xFFFFFF, 0.06), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: c / 2, y: bodyRect.maxY + body * 0.1), startRadius: 0,
                           endCenter: CGPoint(x: c / 2, y: bodyRect.maxY + body * 0.1), endRadius: body * 0.75, options: [])

    // Edge: a hairline that catches the light at the top, so the icon never sinks into a dark Dock.
    let edgeWidth = max(1, 3 * unit)
    ctx.addPath(squircle)
    ctx.setLineWidth(edgeWidth * 2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let edge = CGGradient(colorsSpace: sRGB, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0.04), color(0xFFFFFF, 0.07)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(edge, start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.minY), options: [])
    ctx.restoreGState()

    let center = CGPoint(x: c / 2, y: c / 2)
    let reticle = Reticle(body: body, centerOnPixelEdge: canvas % 2 == 0)
    drawReticle(in: ctx, center: center, reticle, tick: Palette.tick, dot: Palette.dot, dotLight: Palette.dotLight)
    return ctx.makeImage()!
}

/// The menu bar template: black marks on transparent, 18 pt tall. Each scale is laid out on its
/// own pixel grid so the ticks stay sharp.
func renderMenuBarIcon(scale: Int) -> CGImage {
    let side = 18 * scale
    let ctx = makeContext(side, side)
    let s = CGFloat(scale)
    let r: Reticle
    let center: CGPoint
    if scale == 1 {
        center = CGPoint(x: 9, y: 9)
        r = Reticle(tickWidth: 2, dotRadius: 2.5, tickInner: 4, tickOuter: 7, roundCaps: false, glow: false)
    } else {
        // Nudged a quarter point right so the 3 px ticks sit on whole pixels.
        center = CGPoint(x: 9.25 * s, y: 9 * s)
        r = Reticle(tickWidth: 3, dotRadius: 5, tickInner: 8, tickOuter: 14, roundCaps: true, glow: false)
    }
    drawReticle(in: ctx, center: center, r, tick: color(0x000000), dot: nil, dotLight: nil)
    return ctx.makeImage()!
}

extension Reticle {
    init(tickWidth: CGFloat, dotRadius: CGFloat, tickInner: CGFloat, tickOuter: CGFloat, roundCaps: Bool, glow: Bool) {
        self.tickWidth = tickWidth
        self.dotRadius = dotRadius
        self.tickInner = tickInner
        self.tickOuter = tickOuter
        self.roundCaps = roundCaps
        self.glow = glow
    }
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Can't write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Can't write \(url.path)") }
    print("  \(url.path.replacingOccurrences(of: root.path + "/", with: ""))")
}

func writeJSON(_ object: Any, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

let info: [String: Any] = ["author": "xcode", "version": 1]

// App icon
print("AppIcon")
let appIconDir = assets.appendingPathComponent("AppIcon.appiconset")
var rendered: [Int: CGImage] = [:]
for px in [16, 32, 64, 128, 256, 512, 1024] {
    rendered[px] = renderIcon(canvas: px)
    writePNG(rendered[px]!, to: appIconDir.appendingPathComponent("icon_\(px).png"))
}
var appIconImages: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        appIconImages.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x",
                              "filename": "icon_\(points * scale).png"])
    }
}
writeJSON(["images": appIconImages, "info": info], to: appIconDir.appendingPathComponent("Contents.json"))

// Large icon for in-app use
print("AppIconImage")
let appImageDir = assets.appendingPathComponent("AppIconImage.imageset")
writePNG(rendered[512]!, to: appImageDir.appendingPathComponent("AppIconImage.png"))
writePNG(rendered[1024]!, to: appImageDir.appendingPathComponent("AppIconImage@2x.png"))
writeJSON(["images": [
    ["idiom": "universal", "scale": "1x", "filename": "AppIconImage.png"],
    ["idiom": "universal", "scale": "2x", "filename": "AppIconImage@2x.png"],
], "info": info], to: appImageDir.appendingPathComponent("Contents.json"))

// Menu bar
print("MenuBarIcon")
let menuDir = assets.appendingPathComponent("MenuBarIcon.imageset")
writePNG(renderMenuBarIcon(scale: 1), to: menuDir.appendingPathComponent("MenuBarIcon.png"))
writePNG(renderMenuBarIcon(scale: 2), to: menuDir.appendingPathComponent("MenuBarIcon@2x.png"))
writeJSON(["images": [
    ["idiom": "universal", "scale": "1x", "filename": "MenuBarIcon.png"],
    ["idiom": "universal", "scale": "2x", "filename": "MenuBarIcon@2x.png"],
], "info": info, "properties": ["template-rendering-intent": "template"]], to: menuDir.appendingPathComponent("Contents.json"))

// Browser extension: toolbar sizes fill the canvas; store/listing sizes keep Chrome's 1/8 padding.
print("WebExtension")
let extDir = root.appendingPathComponent("WebExtension/icons")
for px in [16, 32, 48, 96, 128] {
    let image = px <= 32
        ? renderIcon(canvas: px, bodyFraction: 1, shadow: false)
        : renderIcon(canvas: px, bodyFraction: 0.75, shadow: true)
    writePNG(image, to: extDir.appendingPathComponent("icon-\(px).png"))
}
