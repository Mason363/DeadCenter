// Renders the README's demos with the reader's own rules: the focus letter centered on the same
// pixel every frame, Spritz-style focus position, and pauses at punctuation.
//
//   swift Scripts/make-readme-gifs.swift
//
// Writes docs/compare.gif, docs/page-mode.gif and docs/speed-*.gif.

import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let background = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
let ink = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
let soft = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 0.82)
let dim = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 0.36)
let quiet = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 0.42)
let faint = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 0.12)
let red = CGColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)

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

/// Dead Center's focus view shows bare words: no quotes, brackets or dashes around them.
func bare(_ word: String) -> String {
    let wrappers = Set("\"'“”‘’()[]{}«»—–")
    var chars = Array(word)
    while let first = chars.first, wrappers.contains(first), chars.count > 1 { chars.removeFirst() }
    var tail: [Character] = []
    while let last = chars.last, chars.count > 1, wrappers.contains(last) || ".,;:!?…".contains(last) {
        chars.removeLast()
        if !wrappers.contains(last) { tail.insert(last, at: 0) }
    }
    return String(chars + tail)
}

func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
}

// MARK: - Drawing

func font(_ size: CGFloat, weight: NSFont.Weight = .medium) -> CTFont {
    NSFont.systemFont(ofSize: size, weight: weight) as CTFont
}

func monospaced(_ size: CGFloat) -> CTFont {
    NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium) as CTFont
}

struct Line {
    let line: CTLine
    let width: CGFloat
    let pivotCenter: CGFloat
}

func typeset(_ text: String, font: CTFont, color: CGColor, highlight: Bool = false) -> Line {
    let attributed = NSMutableAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
    ])
    guard !text.isEmpty else {
        return Line(line: CTLineCreateWithAttributedString(attributed), width: 0, pivotCenter: 0)
    }
    let p = pivot(of: text)
    let start = text.index(text.startIndex, offsetBy: p)
    let range = NSRange(start..<text.index(after: start), in: text)
    if highlight {
        attributed.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: red, range: range)
    }
    let line = CTLineCreateWithAttributedString(attributed)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let a = CTLineGetOffsetForStringIndex(line, range.location, nil)
    let b = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
    return Line(line: line, width: width, pivotCenter: (a + b) / 2)
}

func context(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.textMatrix = .identity
    return ctx
}

/// Draws `text` with its left edge at `x`, or centered on `x`, on the baseline `y`.
func draw(_ text: String, font: CTFont, color: CGColor, x: CGFloat, y: CGFloat, centered: Bool = false, in ctx: CGContext) {
    let line = typeset(text, font: font, color: color)
    ctx.textPosition = CGPoint(x: centered ? x - line.width / 2 : x, y: y)
    CTLineDraw(line.line, ctx)
}

/// One RSVP word with its focus letter on `x`.
func drawFocusWord(_ word: String, size: CGFloat, x: CGFloat, baseline: CGFloat, in ctx: CGContext) {
    guard !word.isEmpty else { return }
    let line = typeset(word, font: font(size), color: ink, highlight: true)
    ctx.textPosition = CGPoint(x: x - line.pivotCenter, y: baseline)
    CTLineDraw(line.line, ctx)
}

/// A paragraph laid out as on a page, word by word, so one word can be marked.
struct Page {
    struct Placed {
        let word: String
        let x: CGFloat
        let baseline: CGFloat
        let width: CGFloat
    }

    let words: [Placed]
    let font: CTFont
    let lineHeight: CGFloat

    init(_ text: String, font: CTFont, width: CGFloat, left: CGFloat, top: CGFloat, lineHeight: CGFloat, canvasHeight: CGFloat) {
        self.font = font
        self.lineHeight = lineHeight
        let space = typeset(" ", font: font, color: ink).width
        var placed: [Placed] = []
        var x: CGFloat = 0
        var row = 0
        for word in DeadCenterReadme.words(text) {
            let w = typeset(word, font: font, color: ink).width
            if x > 0, x + w > width {
                row += 1
                x = 0
            }
            let baseline = canvasHeight - top - CGFloat(row) * lineHeight - CTFontGetAscent(font)
            placed.append(Placed(word: word, x: left + x, baseline: baseline, width: w))
            x += w + space
        }
        words = placed
    }

    /// The page with word `current` marked: lit in red (page mode) or held by the eye (ordinary reading).
    func draw(current: Int?, style: Style, in ctx: CGContext) {
        for (i, word) in words.enumerated() {
            let isCurrent = i == current
            if isCurrent, style == .eye {
                let pad: CGFloat = 5
                let rect = CGRect(x: word.x - pad, y: word.baseline - CTFontGetDescent(font) - 3,
                                  width: word.width + pad * 2, height: CTFontGetAscent(font) + CTFontGetDescent(font) + 6)
                ctx.setFillColor(faint)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            }
            let color: CGColor = switch style {
            case .eye: isCurrent ? ink : dim
            case .page: isCurrent ? red : soft
            }
            ctx.textPosition = CGPoint(x: word.x, y: word.baseline)
            CTLineDraw(typeset(word.word, font: font, color: color).line, ctx)
        }
    }

    enum Style { case eye, page }
}

enum DeadCenterReadme {
    static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
}

func clock(_ seconds: Double) -> String {
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}

func writeGIF(_ frames: [(CGImage, Double)], to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
    CGImageDestinationSetProperties(destination, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
    ] as CFDictionary)
    for (image, seconds) in frames {
        // Browsers honor delays in hundredths of a second, down to 0.02.
        let delay = max((seconds * 100).rounded() / 100, 0.02)
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay],
        ] as CFDictionary)
    }
    CGImageDestinationFinalize(destination)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("\(url.lastPathComponent): \(frames.count) frames, \(size / 1024) KB")
}

/// Start times of each word, and when the last one is done.
func schedule(_ words: [String], wpm: Double, paced: Bool) -> (starts: [Double], end: Double) {
    var t = 0.0
    var starts: [Double] = []
    for word in words {
        starts.append(t)
        t += paced ? duration(of: word, wpm: wpm) : 60 / wpm
    }
    return (starts, t)
}

func index(at t: Double, in starts: [Double]) -> Int {
    starts.lastIndex { $0 <= t + 1e-9 } ?? 0
}

let docs = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs")

// MARK: - Side by side

// The same paragraph read the usual way at the average adult's pace, and in Dead Center at 500 wpm.
let compareText = """
Reading feels effortless, but your eyes are working hard. They jump from word to word several times a \
second, and every jump costs a little time. Dead Center brings each word to the same spot, so your eyes \
can rest and your mind does the reading. Most people are surprised how quickly it starts to feel natural.
"""
do {
    let width = 1200, height = 500
    let half = CGFloat(width) / 2
    let paragraph = words(compareText)
    let slow = schedule(paragraph, wpm: 240, paced: false)
    let fast = schedule(paragraph.map(bare), wpm: 500, paced: true)
    let page = Page(compareText, font: font(21, weight: .regular), width: half - 84, left: 44, top: 150,
                    lineHeight: 33, canvasHeight: CGFloat(height))

    func frame(at t: Double, started: Bool) -> CGImage {
        let ctx = context(width: width, height: height)
        let h = CGFloat(height)
        ctx.setFillColor(faint)
        ctx.fill(CGRect(x: half - 0.5, y: 56, width: 1, height: h - 112))

        draw("Reading the usual way", font: font(21, weight: .semibold), color: soft, x: half / 2, y: h - 58, centered: true, in: ctx)
        draw("240 words a minute, the average adult", font: font(15), color: quiet, x: half / 2, y: h - 84, centered: true, in: ctx)
        draw("Dead Center", font: font(21, weight: .semibold), color: soft, x: half * 1.5, y: h - 58, centered: true, in: ctx)
        draw("500 words a minute", font: font(15), color: quiet, x: half * 1.5, y: h - 84, centered: true, in: ctx)

        let slowDone = started && t >= slow.end
        let fastDone = started && t >= fast.end
        page.draw(current: started && !slowDone ? index(at: t, in: slow.starts) : nil, style: .eye, in: ctx)
        if started && !fastDone {
            drawFocusWord(bare(paragraph[index(at: t, in: fast.starts)]), size: 54, x: half * 1.5, baseline: h / 2 - 22, in: ctx)
        } else if fastDone {
            draw("Done", font: font(46, weight: .semibold), color: ink, x: half * 1.5, y: h / 2 - 22, centered: true, in: ctx)
        }

        let timer = monospaced(19)
        draw(slowDone ? "Done in \(clock(slow.end))" : clock(started ? t : 0), font: timer, color: slowDone ? soft : quiet,
             x: half / 2, y: 44, centered: true, in: ctx)
        draw(fastDone ? "Done in \(clock(fast.end))" : clock(started ? t : 0), font: timer, color: fastDone ? red : quiet,
             x: half * 1.5, y: 44, centered: true, in: ctx)
        return ctx.makeImage()!
    }

    // A frame wherever anything changes: either side's word, or a clock second.
    var events = Set<Double>()
    for s in slow.starts + fast.starts + [slow.end, fast.end] { events.insert((s * 50).rounded() / 50) }
    for second in 0...Int(slow.end) { events.insert(Double(second)) }
    let times = events.sorted()
    var frames: [(CGImage, Double)] = [(frame(at: 0, started: false), 1.2)]
    for (i, t) in times.enumerated() {
        let next = i + 1 < times.count ? times[i + 1] : t + 4
        frames.append((frame(at: t, started: true), next - t))
    }
    writeGIF(frames, to: docs.appendingPathComponent("compare.gif"))
}

// MARK: - Speeds

let speedText = "Read this at your usual pace. Now picture reading it twice as fast and still catching every word."
let speedWords = words(speedText)

// The first rung is ordinary reading, on a page.
do {
    let width = 1200, height = 280
    let page = Page(speedText, font: font(30, weight: .regular), width: 900, left: 150, top: 82, lineHeight: 46,
                    canvasHeight: CGFloat(height))
    let plan = schedule(speedWords, wpm: 240, paced: false)
    var frames: [(CGImage, Double)] = []
    for (i, start) in plan.starts.enumerated() {
        let ctx = context(width: width, height: height)
        page.draw(current: i, style: .eye, in: ctx)
        draw("240 wpm", font: font(16), color: quiet, x: CGFloat(width) / 2, y: 26, centered: true, in: ctx)
        let end = i + 1 < plan.starts.count ? plan.starts[i + 1] : plan.end
        frames.append((ctx.makeImage()!, end - start))
    }
    let rest = context(width: width, height: height)
    page.draw(current: nil, style: .eye, in: rest)
    draw("240 wpm", font: font(16), color: quiet, x: CGFloat(width) / 2, y: 26, centered: true, in: rest)
    frames.append((rest.makeImage()!, 1.4))
    writeGIF(frames, to: docs.appendingPathComponent("speed-240.gif"))
}

for wpm in [450, 700, 1000] {
    let width = 1200, height = 280
    var frames: [(CGImage, Double)] = []
    for word in speedWords {
        let ctx = context(width: width, height: height)
        drawFocusWord(bare(word), size: 78, x: CGFloat(width) / 2, baseline: CGFloat(height) / 2 - 12, in: ctx)
        draw("\(wpm) wpm", font: font(16), color: quiet, x: CGFloat(width) / 2, y: 26, centered: true, in: ctx)
        frames.append((ctx.makeImage()!, duration(of: word, wpm: Double(wpm))))
    }
    let rest = context(width: width, height: height)
    draw("\(wpm) wpm", font: font(16), color: quiet, x: CGFloat(width) / 2, y: 26, centered: true, in: rest)
    frames.append((rest.makeImage()!, 1.4))
    writeGIF(frames, to: docs.appendingPathComponent("speed-\(wpm).gif"))
}

// MARK: - Page mode

let pageText = """
Prefer to see the whole page? Page mode keeps your paragraphs where they are and lights the word you're on \
in red, moving at your speed. Your eyes follow it without hunting for their place, and the page glides up a \
line at a time.
"""
do {
    let width = 1200, height = 250
    let page = Page(pageText, font: font(27, weight: .regular), width: 960, left: 120, top: 58, lineHeight: 44,
                    canvasHeight: CGFloat(height))
    let plan = schedule(words(pageText), wpm: 350, paced: true)
    var frames: [(CGImage, Double)] = []
    for (i, start) in plan.starts.enumerated() {
        let ctx = context(width: width, height: height)
        page.draw(current: i, style: .page, in: ctx)
        let end = i + 1 < plan.starts.count ? plan.starts[i + 1] : plan.end
        frames.append((ctx.makeImage()!, end - start))
    }
    let rest = context(width: width, height: height)
    page.draw(current: nil, style: .page, in: rest)
    frames.append((rest.makeImage()!, 1.6))
    writeGIF(frames, to: docs.appendingPathComponent("page-mode.gif"))
}
