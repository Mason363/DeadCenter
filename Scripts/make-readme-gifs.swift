// Renders the README's reading demos with the reader's own rules: the focus letter centered
// on the same pixel every frame, Spritz-style focus position, and pauses at punctuation.
//
//   swift Scripts/make-readme-gifs.swift
//
// Writes docs/reading.gif and docs/speed-*.gif.

import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let background = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
let ink = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
let dim = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 0.32)
let quiet = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 0.38)
let red = CGColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)

struct Canvas {
    var width: Int
    var height: Int
    var fontSize: CGFloat
    var label: String
}

// MARK: - Reading rules

func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

/// The focus letter, about a third into the word, ignoring punctuation.
func pivot(of word: String) -> Int {
    let chars = Array(word)
    guard let first = chars.firstIndex(where: isWordCharacter),
          let last = chars.lastIndex(where: isWordCharacter) else { return 0 }
    let length = last - first + 1
    let offset = switch length {
    case ...1: 0
    case 2...5: 1
    case 6...9: 2
    case 10...13: 3
    default: 4
    }
    return first + offset
}

/// Seconds on screen at `wpm`: never shorter than one word's time, longer at punctuation and long words.
func duration(of word: String, wpm: Double) -> Double {
    let base = 60 / wpm
    var extra = 0.0
    let letters = word.filter(isWordCharacter).count
    if letters > 6 { extra += min(Double(letters - 6) * 0.07, 0.6) }
    var trimmed = Substring(word)
    while let last = trimmed.last, "\"'”’)".contains(last) { trimmed = trimmed.dropLast() }
    if let last = trimmed.last {
        if ".!?…".contains(last) { extra += 1.2 }
        else if ",;:".contains(last) { extra += 0.5 }
        else if "—–".contains(last) { extra += 0.4 }
    }
    return base * (1 + extra)
}

// MARK: - Drawing

func font(_ size: CGFloat, weight: NSFont.Weight = .medium) -> CTFont {
    NSFont.systemFont(ofSize: size, weight: weight) as CTFont
}

struct Line {
    let line: CTLine
    let width: CGFloat
    let pivotCenter: CGFloat
}

func typeset(_ word: String, size: CGFloat, color: CGColor, highlight: Bool) -> Line {
    let text = NSMutableAttributedString(string: word, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font(size),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
    ])
    guard !word.isEmpty else {
        let line = CTLineCreateWithAttributedString(text)
        return Line(line: line, width: 0, pivotCenter: 0)
    }
    let p = pivot(of: word)
    let start = word.index(word.startIndex, offsetBy: p)
    let range = NSRange(start..<word.index(after: start), in: word)
    if highlight {
        text.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: red, range: range)
    }
    let line = CTLineCreateWithAttributedString(text)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let a = CTLineGetOffsetForStringIndex(line, range.location, nil)
    let b = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
    return Line(line: line, width: width, pivotCenter: (a + b) / 2)
}

func context(_ canvas: Canvas) -> CGContext {
    let ctx = CGContext(data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
    ctx.textMatrix = .identity
    return ctx
}

func baseline(_ canvas: Canvas) -> CGFloat {
    let cap = CTFontGetCapHeight(font(canvas.fontSize))
    return (CGFloat(canvas.height) / 2 - cap / 2 + CGFloat(canvas.height) * 0.04).rounded()
}

func drawLabel(_ text: String, in ctx: CGContext, canvas: Canvas) {
    guard !text.isEmpty else { return }
    let size = canvas.fontSize * 0.2
    let line = typeset(text, size: size, color: quiet, highlight: false)
    let attributed = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font(size, weight: .medium),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): quiet,
    ])
    let plain = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = CGPoint(x: (CGFloat(canvas.width) - line.width) / 2, y: size * 1.6)
    CTLineDraw(plain, ctx)
}

/// One word, its focus letter on the center line.
func frame(_ word: String, canvas: Canvas) -> CGImage {
    let ctx = context(canvas)
    let line = typeset(word, size: canvas.fontSize, color: ink, highlight: true)
    ctx.textPosition = CGPoint(x: CGFloat(canvas.width) / 2 - line.pivotCenter, y: baseline(canvas))
    CTLineDraw(line.line, ctx)
    drawLabel(canvas.label, in: ctx, canvas: canvas)
    return ctx.makeImage()!
}

/// Paused: the sentence around the current word, fading out toward the edges.
func ribbon(_ words: [String], current: Int, canvas: Canvas) -> CGImage {
    let ctx = context(canvas)
    let y = baseline(canvas)
    let space = typeset(" ", size: canvas.fontSize, color: dim, highlight: false).width
    let center = typeset(words[current], size: canvas.fontSize, color: ink, highlight: true)
    var x = CGFloat(canvas.width) / 2 - center.pivotCenter
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(center.line, ctx)
    var right = x + center.width
    for word in words[(current + 1)...] {
        let line = typeset(word, size: canvas.fontSize, color: dim, highlight: false)
        ctx.textPosition = CGPoint(x: right + space, y: y)
        CTLineDraw(line.line, ctx)
        right += space + line.width
    }
    for word in words[..<current].reversed() {
        let line = typeset(word, size: canvas.fontSize, color: dim, highlight: false)
        x -= space + line.width
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line.line, ctx)
    }
    // Fade the edges into the background.
    let fade = CGFloat(canvas.width) * 0.16
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [background, background.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: fade, y: 0), options: [])
    ctx.drawLinearGradient(gradient, start: CGPoint(x: CGFloat(canvas.width), y: 0),
                           end: CGPoint(x: CGFloat(canvas.width) - fade, y: 0), options: [])
    drawLabel(canvas.label, in: ctx, canvas: canvas)
    return ctx.makeImage()!
}

func writeGIF(_ frames: [(CGImage, Double)], to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
    CGImageDestinationSetProperties(destination, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
    ] as CFDictionary)
    for (image, seconds) in frames {
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: seconds,
                                            kCGImagePropertyGIFUnclampedDelayTime: seconds],
        ] as CFDictionary)
    }
    CGImageDestinationFinalize(destination)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("\(url.lastPathComponent): \(frames.count) frames, \(size / 1024) KB")
}

func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
}

let docs = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs")

// MARK: - Hero

let hero = Canvas(width: 1440, height: 420, fontSize: 112, label: "")
let heroText = """
This is Dead Center. Words come to you, one at a time, and the red letter never moves. \
Your eyes stay still, so nothing is spent jumping across lines. You just read, faster and calmer. \
Pause, and the whole sentence is there.
"""
var heroFrames: [(CGImage, Double)] = []
let heroWords = words(heroText)
for word in heroWords {
    heroFrames.append((frame(word, canvas: hero), duration(of: word, wpm: 330)))
}
// End on the paused view of the last sentence.
let lastSentence = words("Pause, and the whole sentence is there.")
heroFrames.append((ribbon(lastSentence, current: 3, canvas: hero), 3.2))
writeGIF(heroFrames, to: docs.appendingPathComponent("reading.gif"))

// MARK: - Speeds

let speedText = """
Most people read about 240 words a minute. Dead Center lets you go further, \
and keeps every word in exactly the same place.
"""
for (wpm, label) in [(250, "250 wpm"), (450, "450 wpm"), (700, "700 wpm")] {
    let canvas = Canvas(width: 1200, height: 280, fontSize: 84, label: label)
    var frames: [(CGImage, Double)] = []
    for word in words(speedText) {
        frames.append((frame(word, canvas: canvas), duration(of: word, wpm: Double(wpm))))
    }
    frames.append((frame("", canvas: canvas), 1.2))
    writeGIF(frames, to: docs.appendingPathComponent("speed-\(wpm).gif"))
}
