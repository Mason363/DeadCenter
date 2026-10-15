import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import DCIngest

/// A white bitmap page drawn with CoreText, addressed from the top-left like a printed page.
final class PageCanvas {
    let size: CGSize
    let context: CGContext

    init(size: CGSize, background: CGColor = CGColor(gray: 1, alpha: 1)) {
        self.size = size
        context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: size))
    }

    static func font(_ name: String, _ size: CGFloat) -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }

    func line(_ text: String, font: CTFont, color: CGColor = CGColor(gray: 0, alpha: 1)) -> CTLine {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        return CTLineCreateWithAttributedString(attributed)
    }

    func width(_ text: String, font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font: font), nil, nil, nil))
    }

    /// Draws `text` with its baseline `baseline` pixels from the top. A `justify` width stretches it to fill.
    func text(_ text: String, x: CGFloat, baseline: CGFloat, font: CTFont, color: CGColor = CGColor(gray: 0, alpha: 1),
              justify: CGFloat? = nil) {
        var ctLine = line(text, font: font, color: color)
        if let justify {
            precondition(width(text, font: font) <= justify, "line too long for its column: \(text)")
            ctLine = CTLineCreateJustifiedLine(ctLine, 1, Double(justify)) ?? ctLine
        }
        context.textPosition = CGPoint(x: x, y: size.height - baseline)
        CTLineDraw(ctLine, context)
    }

    func centered(_ text: String, centerX: CGFloat, baseline: CGFloat, font: CTFont) {
        self.text(text, x: centerX - width(text, font: font) / 2, baseline: baseline, font: font)
    }

    /// A rectangle given from the top-left, in CoreGraphics' bottom-left space.
    func rect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: size.height - top - height, width: width, height: height)
    }

    func point(_ x: CGFloat, _ top: CGFloat) -> CGPoint {
        CGPoint(x: x, y: size.height - top)
    }

    /// Sets paragraphs (each a list of lines) in a column, justifying all but each paragraph's
    /// last line and indenting first lines. Returns the baseline after the last line.
    @discardableResult
    func column(_ paragraphs: [[String]], x: CGFloat, width: CGFloat, baseline: CGFloat, font: CTFont, leading: CGFloat,
                indent: CGFloat = 0, indentFirst: Bool = false, lastLineJustified: Bool = false) -> CGFloat {
        var y = baseline
        for (p, lines) in paragraphs.enumerated() {
            for (i, text) in lines.enumerated() {
                let inset = i == 0 && (p > 0 || indentFirst) ? indent : 0
                let isLast = i == lines.count - 1 && !(lastLineJustified && p == paragraphs.count - 1)
                self.text(text, x: x + inset, baseline: y, font: font, justify: isLast ? nil : width - inset)
                y += leading
            }
        }
        return y
    }

    func image() -> CGImage { context.makeImage()! }
}

/// Synthetic textbook pages and photos of them for the page-scan tests.
enum ScanFixture {
    static let pageSize = CGSize(width: 1700, height: 2200)
    static let header = "EARTH SCIENCE · CHAPTER 2"
    static let pageNumber = "37"
    static let heading = "The Water Cycle"
    static let equation = "P = E + R + ΔS"
    static let caption = "Figure 2.3 The water cycle moves water between the oceans, the air and the land."
    static let labels = ["Transpiration", "Infiltration"]

    static let leftColumn: [[String]] = [
        [
            "Water is always on the move. It rises from the",
            "oceans as vapor, drifts across the sky in clouds",
            "and falls back to the ground as rain or snow.",
            "Scientists call this endless loop the water cycle,",
            "and it shapes the weather, the land and every",
            "living thing on our planet.",
        ],
        [
            "The sun supplies the energy for the whole",
            "cycle. Its heat warms the surface of lakes and",
            "seas, and liquid water turns into vapor by evapo-",
            "ration, which carries moisture high into the cool",
            "air above the ground. Over a full year the flows",
            "balance, which we can write as",
        ],
    ]

    /// Set below the equation, running on into the right column.
    static let afterEquation: [String] = [
        "where P is precipitation, E is evaporation, R is",
        "runoff and the last term is the change in the",
        "water stored in soil, lakes and ice. Each term is",
        "usually measured in millimeters of water spread",
        "evenly over the whole area of a river basin, and",
    ]

    static let rightColumn: [[String]] = [
        ["the same units make it easy to compare places."],
        [
            "Clouds form when rising air cools and its",
            "vapor condenses on tiny grains of dust or salt.",
            "When the droplets grow heavy enough they fall",
            "as precipitation. Most of it lands in the sea,",
            "but a large share falls on the continents.",
        ],
        [
            "On land, water follows several paths. Some",
            "soaks into the soil and recharges groundwater,",
            "some is taken up by plant roots, and the rest",
            "runs downhill into streams and rivers that carry",
            "it back to the ocean. A single molecule may spend",
            "days in the air but thousands of years locked in",
            "deep aquifers or polar ice before it moves on.",
        ],
        [
            "Because the cycle links the air, the land and",
            "the sea, a change in one part is felt in the",
            "others, which is why climate scientists watch",
            "it closely.",
        ],
    ]

    static let closing: [String] = [
        "The diagram above summarizes these paths. In the sections that follow we look at each stage",
        "in turn, starting with evaporation from the surface of the ocean.",
    ]

    /// The page's paragraphs as they should read, in order.
    static var paragraphs: [String] {
        func joined(_ lines: [String]) -> String {
            lines.reduce("") { TextNormalizer.join($0, $1) }
        }
        return [joined(leftColumn[0]), joined(leftColumn[1]), joined(afterEquation + rightColumn[0])]
            + rightColumn.dropFirst().map(joined) + [joined(closing)]
    }

    /// A two-column textbook page: running header and page number, chapter heading, a word
    /// hyphenated across a line break, a display equation, and a labeled figure with a caption.
    static func textbookPage() -> CGImage {
        let page = PageCanvas(size: pageSize)
        let body = PageCanvas.font("Times-Roman", 30)
        let small = PageCanvas.font("Helvetica", 24)
        let leading: CGFloat = 40
        let left: CGFloat = 130, gutter: CGFloat = 80, columnWidth: CGFloat = 680
        let right = left + columnWidth + gutter

        page.text(header, x: left, baseline: 100, font: small)
        page.text(pageNumber, x: pageSize.width - left - page.width(pageNumber, font: small), baseline: 100, font: small)
        page.text(heading, x: left, baseline: 250, font: PageCanvas.font("Times-Bold", 76))

        var y = page.column(leftColumn, x: left, width: columnWidth, baseline: 360, font: body, leading: leading, indent: 40)
        y += 30
        page.centered(equation, centerX: left + columnWidth / 2, baseline: y, font: PageCanvas.font("Times-Italic", 38))
        y += leading + 40
        page.column([afterEquation], x: left, width: columnWidth, baseline: y, font: body, leading: leading, lastLineJustified: true)
        page.column(rightColumn, x: right, width: columnWidth, baseline: 360, font: body, leading: leading, indent: 40)

        let figure = page.rect(x: 230, top: 1190, width: 1240, height: 660)
        drawFigure(in: figure, on: page)
        page.text(caption, x: figure.minX, baseline: 1905, font: PageCanvas.font("Times-Italic", 28))
        page.column([closing], x: left, width: pageSize.width - 2 * left, baseline: 2010, font: body, leading: leading)
        return page.image()
    }

    /// A landscape of sea, land, sun and cloud: shapes, a sky gradient, arrows and two labels.
    static func drawFigure(in frame: CGRect, on page: PageCanvas) {
        let ctx = page.context
        ctx.saveGState()
        ctx.clip(to: frame)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let sky = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.35, green: 0.55, blue: 0.85, alpha: 1), CGColor(red: 0.72, green: 0.84, blue: 0.96, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: frame.midX, y: frame.maxY), end: CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.3), options: [])

        // Sea on the left with a wavy surface, land rising to a mountain on the right.
        let seaTop = frame.minY + frame.height * 0.3
        ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1))
        let sea = CGMutablePath()
        sea.move(to: CGPoint(x: frame.minX, y: frame.minY))
        sea.addLine(to: CGPoint(x: frame.minX, y: seaTop))
        for i in 0..<6 {
            let x0 = frame.minX + CGFloat(i) * 90
            sea.addQuadCurve(to: CGPoint(x: x0 + 90, y: seaTop), control: CGPoint(x: x0 + 45, y: seaTop + (i.isMultiple(of: 2) ? 22 : -22)))
        }
        sea.addLine(to: CGPoint(x: frame.minX + 540, y: frame.minY))
        sea.closeSubpath()
        ctx.addPath(sea)
        ctx.fillPath()

        ctx.setFillColor(CGColor(red: 0.36, green: 0.52, blue: 0.26, alpha: 1))
        let land = CGMutablePath()
        land.move(to: CGPoint(x: frame.minX + 540, y: frame.minY))
        land.addLine(to: CGPoint(x: frame.minX + 540, y: seaTop))
        land.addLine(to: CGPoint(x: frame.minX + 820, y: seaTop + 60))
        land.addLine(to: CGPoint(x: frame.minX + 1040, y: frame.minY + frame.height * 0.78))
        land.addLine(to: CGPoint(x: frame.maxX, y: seaTop + 120))
        land.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
        land.closeSubpath()
        ctx.addPath(land)
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1))
        let snow = CGMutablePath()
        snow.move(to: CGPoint(x: frame.minX + 1040, y: frame.minY + frame.height * 0.78))
        snow.addLine(to: CGPoint(x: frame.minX + 985, y: frame.minY + frame.height * 0.66))
        snow.addLine(to: CGPoint(x: frame.minX + 1095, y: frame.minY + frame.height * 0.67))
        snow.closeSubpath()
        ctx.addPath(snow)
        ctx.fillPath()

        // Sun and cloud.
        let sun = CGRect(x: frame.minX + 60, y: frame.maxY - 190, width: 130, height: 130)
        ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: sun)
        ctx.setStrokeColor(CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1))
        ctx.setLineWidth(6)
        ctx.strokeEllipse(in: sun)
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
        ctx.setLineWidth(4)
        for puff in [CGRect(x: 520, y: 0, width: 200, height: 110), CGRect(x: 620, y: 30, width: 220, height: 130), CGRect(x: 760, y: 0, width: 190, height: 105)] {
            let r = puff.offsetBy(dx: frame.minX, dy: frame.maxY - 210)
            ctx.fillEllipse(in: r)
            ctx.strokeEllipse(in: r)
        }

        // Arrows: evaporation up from the sea, rain down onto the land, runoff back to the sea.
        ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.setLineWidth(6)
        func arrow(_ from: CGPoint, _ to: CGPoint) {
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = CGMutablePath()
            head.move(to: to)
            head.addLine(to: CGPoint(x: to.x - 30 * cos(angle - 0.4), y: to.y - 30 * sin(angle - 0.4)))
            head.addLine(to: CGPoint(x: to.x - 30 * cos(angle + 0.4), y: to.y - 30 * sin(angle + 0.4)))
            head.closeSubpath()
            ctx.addPath(head)
            ctx.fillPath()
        }
        arrow(CGPoint(x: frame.minX + 300, y: seaTop + 40), CGPoint(x: frame.minX + 540, y: frame.maxY - 160))
        arrow(CGPoint(x: frame.minX + 960, y: frame.maxY - 170), CGPoint(x: frame.minX + 1060, y: frame.maxY - 330))
        arrow(CGPoint(x: frame.minX + 820, y: seaTop + 20), CGPoint(x: frame.minX + 600, y: seaTop - 40))
        ctx.setLineWidth(3)
        for i in 0..<7 {
            let x = frame.minX + 640 + CGFloat(i) * 35
            ctx.move(to: CGPoint(x: x, y: frame.maxY - 230))
            ctx.addLine(to: CGPoint(x: x - 14, y: frame.maxY - 290))
        }
        ctx.strokePath()
        ctx.restoreGState()

        let label = PageCanvas.font("Helvetica", 26)
        let labelTop = page.size.height - frame.maxY
        page.text(labels[0], x: frame.minX + 1060, baseline: labelTop + 120, font: label)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fill(page.rect(x: frame.minX + 820, top: labelTop + 520, width: 200, height: 44))
        page.text(labels[1], x: frame.minX + 832, baseline: labelTop + 552, font: label)
    }

    /// The page as a phone photo: tilted in perspective on a darker textured desk, unevenly lit, saved as JPEG.
    static func photo(of page: CGImage, size: CGSize = CGSize(width: 2000, height: 2600), tilt: Double = 24, turn: Double = -9,
                      roll: Double = 3, quality: CGFloat = 0.88) -> Data {
        let extent = CGRect(origin: .zero, size: size)
        let desk = CIFilter.linearGradient()
        desk.point0 = CGPoint(x: 0, y: 0)
        desk.point1 = CGPoint(x: size.width, y: size.height)
        desk.color0 = CIColor(red: 0.22, green: 0.17, blue: 0.13)
        desk.color1 = CIColor(red: 0.42, green: 0.34, blue: 0.27)
        let grain = CIFilter.randomGenerator().outputImage!
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.06, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.06, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.06, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.03, y: -0.03, z: -0.03, w: 0),
            ])
        let background = grain.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: desk.outputImage!]).cropped(to: extent)

        let corners = projectedCorners(of: CGSize(width: page.width, height: page.height), in: size, tilt: tilt, turn: turn, roll: roll)
        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = CIImage(cgImage: page)
        warp.topLeft = corners[0]
        warp.topRight = corners[1]
        warp.bottomRight = corners[2]
        warp.bottomLeft = corners[3]
        let composed = warp.outputImage!.composited(over: background)

        let light = CIFilter.radialGradient()
        light.center = CGPoint(x: size.width * 0.7, y: size.height * 0.75)
        light.radius0 = 300
        light.radius1 = Float(size.height * 0.95)
        light.color0 = CIColor(red: 1, green: 1, blue: 0.97)
        light.color1 = CIColor(red: 0.62, green: 0.6, blue: 0.56)
        let lit = composed.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: light.outputImage!.cropped(to: extent)])
        let noisy = CIFilter.randomGenerator().outputImage!
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.025, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.025, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.025, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.0125, y: -0.0125, z: -0.0125, w: 0),
            ])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: lit])
            .cropped(to: extent)

        let context = CIContext()
        let image = context.createCGImage(noisy, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        return jpeg(image, quality: quality)
    }

    /// Where a page's corners land (top-left, top-right, bottom-right, bottom-left; origin
    /// bottom-left) when a pinhole camera looks at it tilted back, turned a little and rolled,
    /// centered in a frame of `frame`.
    static func projectedCorners(of page: CGSize, in frame: CGSize, tilt: Double = 24, turn: Double = -9, roll: Double = 3) -> [CGPoint] {
        let w = 1.0, h = Double(page.height / page.width)
        let (a, b, c) = (tilt * .pi / 180, turn * .pi / 180, roll * .pi / 180)
        func rotate(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let x1 = SIMD3(p.x, p.y * cos(a) - p.z * sin(a), p.y * sin(a) + p.z * cos(a))
            let x2 = SIMD3(x1.x * cos(b) + x1.z * sin(b), x1.y, -x1.x * sin(b) + x1.z * cos(b))
            return SIMD3(x2.x * cos(c) - x2.y * sin(c), x2.x * sin(c) + x2.y * cos(c), x2.z)
        }
        let distance = 2.2
        let points = [SIMD3(-w / 2, h / 2, 0), SIMD3(w / 2, h / 2, 0), SIMD3(w / 2, -h / 2, 0), SIMD3(-w / 2, -h / 2, 0)]
            .map { p -> (Double, Double) in
                let q = rotate(p)
                return (q.x / (distance + q.z), q.y / (distance + q.z))
            }
        // Scale so the page fills most of the frame, keeping the principal point at its center.
        let spanX = points.map { abs($0.0) }.max()!, spanY = points.map { abs($0.1) }.max()!
        let focal = min(Double(frame.width) * 0.46 / spanX, Double(frame.height) * 0.46 / spanY)
        return points.map { CGPoint(x: Double(frame.width) / 2 + $0.0 * focal, y: Double(frame.height) / 2 + $0.1 * focal) }
    }

    static func jpeg(_ image: CGImage, quality: CGFloat = 0.92) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Three book pages with the same running header; the second paragraph runs across the first page break.
    static let bookHeader = "Understanding Earth Science"
    static let bookPages: [[[String]]] = [
        [
            [
                "Rivers are the veins of the land. They gather rain from hills and fields and carry",
                "it, along with sand and mud, all the way down to the sea.",
            ],
            [
                "A river changes as it travels. Near its source it is narrow and fast, cutting deep",
                "valleys into the rock. Further down it slows, widens and begins to wander across the",
            ],
        ],
        [
            ["plain in great loops called meanders, dropping the sediment it can no longer carry."],
            [
                "Where a river meets the sea it may build a delta, a fan of new land made from the",
                "mud it has carried for hundreds of miles.",
            ],
        ],
        [
            [
                "Floods are part of this natural rhythm. They spread fresh soil across the valley",
                "floor, which is why farmers have always settled close to rivers despite the risk.",
            ],
        ],
    ]

    static var bookParagraphs: [String] {
        func joined(_ lines: [String]) -> String { lines.reduce("") { TextNormalizer.join($0, $1) } }
        let p = bookPages
        return [joined(p[0][0]), joined(p[0][1] + p[1][0]), joined(p[1][1]), joined(p[2][0])]
    }

    static func bookImages() -> [CGImage] {
        bookPages.enumerated().map { i, paragraphs in
            bookPage(header: bookHeader, number: 41 + i, paragraphs: paragraphs, lastLineJustified: i == 0)
        }
    }

    /// A simple single-column page with a running header and a page number footer.
    static func bookPage(header: String, number: Int, paragraphs: [[String]], size: CGSize = CGSize(width: 1275, height: 1650),
                         lastLineJustified: Bool = false, startsWithIndent: Bool = false) -> CGImage {
        let page = PageCanvas(size: size)
        let body = PageCanvas.font("Times-Roman", 25)
        page.text(header, x: 120, baseline: 90, font: body)
        page.column(paragraphs, x: 120, width: size.width - 240, baseline: 190, font: body, leading: 34, indent: 36,
                    indentFirst: startsWithIndent, lastLineJustified: lastLineJustified)
        page.centered("Page \(number)", centerX: size.width / 2, baseline: size.height - 80, font: body)
        return page.image()
    }

    static let paperIntro = [
        "Rivers move an enormous amount of sediment every year, and most of it travels during a few",
        "large floods rather than in ordinary weather. Measuring that load is difficult, because the",
        "water is fastest and muddiest exactly when it is most dangerous to stand in the channel.",
    ]
    static let paperMethods = [
        "We sampled three rivers once a week for two years and after every flood. The results are",
        "summarized below, together with the area each river drains.",
    ]
    static let paperAfterFigure = [
        "Load rises steeply with discharge, so a handful of days account for most of the yearly total.",
    ]
    static let paperFootnote = "1 Samples were filtered and dried at 105 degrees before weighing."
    static let tableCaption = "Table 1 Sediment load of the three rivers"
    static let tableCells = [["River", "Area (km2)", "Load (t/yr)"], ["Alder", "1,240", "86,000"], ["Birch", "3,910", "214,000"], ["Cedar", "760", "41,500"]]
    static let paperFigureCaption = "Fig. 2. Sediment load against discharge for the Birch River."

    /// A single-column paper page: centered title, section headings, a fully ruled table with its
    /// caption above, a chart with its caption below, a footnote, and a page number.
    static func paperPage() -> CGImage {
        let page = PageCanvas(size: pageSize)
        let body = PageCanvas.font("Times-Roman", 30)
        let bold = PageCanvas.font("Times-Bold", 36)
        let left: CGFloat = 170, width: CGFloat = pageSize.width - 2 * left
        page.centered("Notes on River Sediment", centerX: pageSize.width / 2, baseline: 180, font: PageCanvas.font("Times-Bold", 64))
        page.centered("A. Rivera and J. Okafor", centerX: pageSize.width / 2, baseline: 250, font: PageCanvas.font("Times-Italic", 30))
        page.text("1 Introduction", x: left, baseline: 360, font: bold)
        var y = page.column([paperIntro], x: left, width: width, baseline: 420, font: body, leading: 40)
        page.text("2 Methods", x: left, baseline: y + 40, font: bold)
        y = page.column([paperMethods], x: left, width: width, baseline: y + 100, font: body, leading: 40)

        // The table: caption above, a ruled grid of cells.
        page.centered(tableCaption, centerX: pageSize.width / 2, baseline: y + 40, font: PageCanvas.font("Times-Italic", 28))
        let tableTop = y + 70, rowHeight: CGFloat = 56, columnWidths: [CGFloat] = [300, 300, 300]
        let tableLeft = (pageSize.width - columnWidths.reduce(0, +)) / 2
        let ctx = page.context
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(3)
        for row in 0...tableCells.count {
            let ty = tableTop + CGFloat(row) * rowHeight
            ctx.move(to: page.point(tableLeft, ty))
            ctx.addLine(to: page.point(tableLeft + columnWidths.reduce(0, +), ty))
        }
        var x = tableLeft
        for column in 0...columnWidths.count {
            ctx.move(to: page.point(x, tableTop))
            ctx.addLine(to: page.point(x, tableTop + CGFloat(tableCells.count) * rowHeight))
            if column < columnWidths.count { x += columnWidths[column] }
        }
        ctx.strokePath()
        for (r, cells) in tableCells.enumerated() {
            var cx = tableLeft
            for (c, cell) in cells.enumerated() {
                page.text(cell, x: cx + 20, baseline: tableTop + CGFloat(r) * rowHeight + 38, font: r == 0 ? PageCanvas.font("Times-Bold", 26) : PageCanvas.font("Times-Roman", 26))
                cx += columnWidths[c]
            }
        }
        y = tableTop + CGFloat(tableCells.count) * rowHeight + 90

        // The chart: axes, ticks with numbers, a curve; caption below.
        let chart = page.rect(x: 450, top: y, width: 800, height: 480)
        ctx.setLineWidth(4)
        ctx.move(to: CGPoint(x: chart.minX, y: chart.maxY))
        ctx.addLine(to: CGPoint(x: chart.minX, y: chart.minY))
        ctx.addLine(to: CGPoint(x: chart.maxX, y: chart.minY))
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        ctx.setLineWidth(5)
        ctx.move(to: CGPoint(x: chart.minX + 10, y: chart.minY + 10))
        for i in 1...40 {
            let t = CGFloat(i) / 40
            ctx.addLine(to: CGPoint(x: chart.minX + 10 + t * (chart.width - 30), y: chart.minY + 10 + pow(t, 2.6) * (chart.height - 30)))
        }
        ctx.strokePath()
        let tick = PageCanvas.font("Helvetica", 22)
        for i in 0...4 {
            let tx = chart.minX + CGFloat(i) * chart.width / 4
            page.centered("\(i * 50)", centerX: tx, baseline: page.size.height - chart.minY + 30, font: tick)
        }
        y += 480 + 80
        page.text(paperFigureCaption, x: 450, baseline: y, font: PageCanvas.font("Times-Italic", 28))
        page.column([paperAfterFigure], x: left, width: width, baseline: y + 80, font: body, leading: 40)

        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(2)
        ctx.move(to: page.point(left, 2020))
        ctx.addLine(to: page.point(left + 400, 2020))
        ctx.strokePath()
        page.text(paperFootnote, x: left, baseline: 2058, font: PageCanvas.font("Times-Roman", 22))
        page.centered("7", centerX: pageSize.width / 2, baseline: 2130, font: PageCanvas.font("Times-Roman", 26))
        return page.image()
    }

    /// Two columns above a full-width figure and two more below it: the figure splits the page into bands.
    static func bandedPage() -> CGImage {
        let page = PageCanvas(size: pageSize)
        let body = PageCanvas.font("Times-Roman", 30)
        let left: CGFloat = 130, columnWidth: CGFloat = 680, right: CGFloat = 890
        page.column([leftColumn[0]], x: left, width: columnWidth, baseline: 200, font: body, leading: 40)
        page.column([Array(rightColumn[1])], x: right, width: columnWidth, baseline: 200, font: body, leading: 40)
        let figure = page.rect(x: 230, top: 520, width: 1240, height: 660)
        drawFigure(in: figure, on: page)
        page.text(caption, x: figure.minX, baseline: 1235, font: PageCanvas.font("Times-Italic", 28))
        page.column([Array(rightColumn[2])], x: left, width: columnWidth, baseline: 1340, font: body, leading: 40)
        page.column([Array(rightColumn[3])], x: right, width: columnWidth, baseline: 1340, font: body, leading: 40)
        return page.image()
    }

    static let marginNotes = ["Key term:", "evaporation"]

    /// A single column of text with a short note in the wide left margin.
    static func marginNotePage() -> CGImage {
        let page = PageCanvas(size: pageSize)
        let body = PageCanvas.font("Times-Roman", 30)
        page.column([leftColumn[0], leftColumn[1], afterEquation], x: 520, width: 680, baseline: 300, font: body, leading: 40, indent: 40)
        page.text(marginNotes[0], x: 150, baseline: 580, font: PageCanvas.font("Helvetica-Bold", 24))
        page.text(marginNotes[1], x: 150, baseline: 612, font: PageCanvas.font("Helvetica", 24))
        return page.image()
    }

    /// A page holding only a figure.
    static func figurePage() -> CGImage {
        let page = PageCanvas(size: pageSize)
        drawFigure(in: page.rect(x: 150, top: 400, width: 1400, height: 1200), on: page)
        return page.image()
    }

    static let sidebarPageLeft = [leftColumn[0], Array(leftColumn[1].dropLast()) + ["balance over the course of the seasons."]]
    static let sidebarHeading = "Did you know?"
    static let sidebarText = [
        "A single thunderstorm can drop more",
        "than a hundred million tonnes of rain,",
        "yet the water vapor that feeds it was",
        "lifted from the sea only days before.",
    ]

    /// Two columns of body text with a tinted box of prose (a sidebar) in the right column.
    static func sidebarPage() -> CGImage {
        let page = PageCanvas(size: pageSize)
        let body = PageCanvas.font("Times-Roman", 30)
        let left: CGFloat = 130, gutter: CGFloat = 80, columnWidth: CGFloat = 680
        let right = left + columnWidth + gutter
        page.text("Storms", x: left, baseline: 220, font: PageCanvas.font("Times-Bold", 76))
        page.column(sidebarPageLeft, x: left, width: columnWidth, baseline: 340, font: body, leading: 40, indent: 40)
        page.column(Array(rightColumn.dropFirst()), x: right, width: columnWidth, baseline: 340, font: body, leading: 40, indent: 40, indentFirst: true)
        let box = page.rect(x: right, top: 1080, width: columnWidth, height: 300)
        page.context.setFillColor(CGColor(red: 0.85, green: 0.92, blue: 1, alpha: 1))
        page.context.fill(box)
        page.text(sidebarHeading, x: right + 30, baseline: 1140, font: PageCanvas.font("Helvetica-Bold", 32))
        page.column([sidebarText], x: right + 30, width: columnWidth - 60, baseline: 1200, font: PageCanvas.font("Helvetica", 28), leading: 40)
        return page.image()
    }

    static let screenshotNote = [
        "We left the house just after six, when the fields were still grey with dew and the",
        "first blackbirds had started singing in the hedges along the lane. By the time we",
        "reached the old bridge the sun was up, and a heron lifted slowly off the water as",
        "we watched.",
    ]

    /// A screenshot of a notes app: toolbar with window controls and a button, a sidebar, and a note.
    static func screenshot() -> CGImage {
        let size = CGSize(width: 1440, height: 900)
        let page = PageCanvas(size: size)
        let ctx = page.context
        let white = CGColor(gray: 1, alpha: 1)
        ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
        ctx.fill(page.rect(x: 0, top: 0, width: size.width, height: 56))
        for (i, color) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                           CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: page.rect(x: 13 + CGFloat(i) * 24, top: 21, width: 14, height: 14))
        }
        page.centered("Field Notes", centerX: size.width / 2, baseline: 34, font: PageCanvas.font("Helvetica-Bold", 16))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.95, alpha: 1))
        ctx.addPath(CGPath(roundedRect: page.rect(x: 1300, top: 14, width: 100, height: 28), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        page.text("Share", x: 1330, baseline: 33, font: PageCanvas.font("Helvetica", 15), color: white)

        ctx.setFillColor(CGColor(gray: 0.965, alpha: 1))
        ctx.fill(page.rect(x: 0, top: 56, width: 280, height: size.height - 56))
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(page.rect(x: 280, top: 56, width: 1, height: size.height - 56))
        let item = PageCanvas.font("Helvetica", 17)
        page.text("All Notes", x: 28, baseline: 100, font: item)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.95, alpha: 1))
        ctx.addPath(CGPath(roundedRect: page.rect(x: 14, top: 114, width: 252, height: 32), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        page.text("Walks", x: 28, baseline: 136, font: item, color: white)
        page.text("Birds", x: 28, baseline: 172, font: item)

        page.text("Morning walk", x: 330, baseline: 130, font: PageCanvas.font("Helvetica-Bold", 30))
        page.text("Saturday, 12 April", x: 330, baseline: 162, font: PageCanvas.font("Helvetica", 15), color: CGColor(gray: 0.5, alpha: 1))
        page.column([screenshotNote], x: 330, width: 1040, baseline: 212, font: PageCanvas.font("Helvetica", 20), leading: 30)
        return page.image()
    }

    /// A multi-page TIFF of the given pages.
    static func tiff(_ pages: [CGImage]) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, pages.count, nil)!
        for page in pages { CGImageDestinationAddImage(dest, page, nil) }
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// A PDF whose pages are only pictures (scans), one per image, without a text layer.
    static func scannedPDF(_ pages: [CGImage]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for page in pages {
            ctx.beginPDFPage(nil)
            ctx.draw(page, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage {
        let ctx = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(image.width))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(image.height), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    /// Words of some text, lowercased, for comparing what two readings recovered.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Fraction of `reference`'s words (counted with multiplicity) also found in `text`.
    static func recall(of reference: String, in text: String) -> Double {
        var available = Dictionary(words(text).map { ($0, 1) }, uniquingKeysWith: +)
        let wanted = words(reference)
        guard !wanted.isEmpty else { return 1 }
        var found = 0
        for word in wanted where (available[word] ?? 0) > 0 {
            available[word]! -= 1
            found += 1
        }
        return Double(found) / Double(wanted.count)
    }
}
