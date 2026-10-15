import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Pages waiting to be read: photos and scans from the iPhone, or images dropped in.
@Observable
final class ScanDraft {
    static let shared = ScanDraft()

    struct Page: Identifiable {
        let id = UUID()
        /// The page as a JPEG, upright and at most 3000 px on its long side.
        let jpeg: Data
        let thumbnail: NSImage
    }

    private(set) var pages: [Page] = []
    /// Pages still being prepared.
    private(set) var pending = 0
    /// The view that receives Continuity Camera results and anchors its menu.
    @ObservationIgnored weak var camera: ContinuityCameraView?

    func add(images: [Data]) {
        pending += images.count
        Task {
            for data in images {
                let page = await Self.prepare(data)
                pending -= 1
                if let page { pages.append(Page(jpeg: page.jpeg, thumbnail: NSImage(data: page.thumbnail) ?? NSImage())) }
            }
        }
    }

    /// A scan from the iPhone's document camera arrives as a PDF: each page becomes an image.
    func add(pdf: Data) {
        pending += 1
        Task {
            let images = await Self.render(pdf)
            pending -= 1
            add(images: images)
        }
    }

    func remove(_ id: Page.ID) {
        pages.removeAll { $0.id == id }
    }

    /// Saves the pages as one scan and starts reading it.
    func read() {
        guard !pages.isEmpty, let url = ScanStore.save(pages.map(\.jpeg)) else { return }
        pages = []
        LibraryState.shared.scanning = false
        ReadingCoordinator.shared.read(.file(url))
    }

    // MARK: - Preparing pages

    @concurrent private nonisolated static func prepare(_ data: Data) async -> (jpeg: Data, thumbnail: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let page = thumbnail(source, maxPixelSize: 3000),
              let jpeg = encode(page, type: .jpeg, quality: 0.88),
              let small = thumbnail(source, maxPixelSize: 420),
              let preview = encode(small, type: .jpeg, quality: 0.8) else { return nil }
        return (jpeg, preview)
    }

    @concurrent private nonisolated static func render(_ pdf: Data) async -> [Data] {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else { return [] }
        var images: [Data] = []
        for number in 1...max(document.numberOfPages, 1) {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.cropBox)
            let scale = min(2600 / max(box.width, box.height, 1), 4)
            let width = Int(box.width * scale), height = Int(box.height * scale)
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            if let image = context.makeImage(), let data = encode(image, type: .jpeg, quality: 0.9) { images.append(data) }
        }
        return images
    }

    private nonisolated static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    nonisolated static func encode(_ image: CGImage, type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Where scans live, so they can be resumed from the Library like any document.
enum ScanStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dead Center/Scans", isDirectory: true)
    }

    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    /// Writes the pages into one PDF. The JPEGs go in as they are, at 144 dpi.
    static func save(_ pages: [Data]) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = directory.appendingPathComponent("Scan \(formatter.string(from: Date())).pdf")
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else { return nil }
        for data in pages {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return url
    }
}

// MARK: - Continuity Camera

/// Receives photos and document scans from a nearby iPhone or iPad (Continuity Camera), and
/// shows the menu that starts them.
final class ContinuityCameraView: NSView, NSServicesMenuRequestor {
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.heic.identifier), NSPasteboard.PasteboardType(UTType.jpeg.identifier), .png, .tiff,
    ]

    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, returnType == .pdf || Self.imageTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if let pdf = pasteboard.data(forType: .pdf) {
            ScanDraft.shared.add(pdf: pdf)
            return true
        }
        let images = (pasteboard.pasteboardItems ?? []).compactMap { item in
            Self.imageTypes.lazy.compactMap { item.data(forType: $0) }.first
        }
        guard !images.isEmpty else { return false }
        ScanDraft.shared.add(images: images)
        return true
    }

    /// The system fills this menu with Take Photo and Scan Documents for each nearby device.
    func showMenu() {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: self)
    }
}

private struct CameraAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> ContinuityCameraView {
        let view = ContinuityCameraView()
        ScanDraft.shared.camera = view
        return view
    }

    func updateNSView(_ view: ContinuityCameraView, context: Context) {
        ScanDraft.shared.camera = view
    }
}

// MARK: - Page

/// Photograph pages with the iPhone (or drop photos and scans), then read them.
struct ScanPage: View {
    @Environment(\.settingsTheme) private var theme
    @State private var dropTargeted = false
    private var draft: ScanDraft { ScanDraft.shared }

    var body: some View {
        ZStack {
            if draft.pages.isEmpty && draft.pending == 0 {
                empty.transition(.opacity)
            } else {
                tray.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: drop)
        .overlay(alignment: .topLeading) {
            BackButton(title: "Home") { LibraryState.shared.scanning = false }
                .padding(.leading, 78)
                .frame(height: 36)
                .padding(.top, 4)
                .ignoresSafeArea(.container, edges: .top)
        }
        .animation(.smooth(duration: 0.25), value: draft.pages.isEmpty && draft.pending == 0)
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 46, weight: .ultraLight))
                .foregroundStyle(theme.ink.opacity(dropTargeted ? 0.9 : 0.5))
            VStack(spacing: 6) {
                Text("Scan a page")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.9))
                Text("Photograph a textbook page or a paper with your iPhone,\nor drop photos and scans here.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.ink.opacity(0.5))
            }
            CameraButton(title: "Use iPhone…", prominent: true)
            Text("Your iPhone needs to be nearby, on the same Apple Account, with Wi‑Fi and Bluetooth on.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(theme.ink.opacity(0.32))
        }
        .padding(40)
        .frame(maxWidth: 520)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(theme.ink.opacity(dropTargeted ? 0.4 : 0), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    private var tray: some View {
        VStack(spacing: 26) {
            GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(draft.pages.enumerated()), id: \.element.id) { number, page in
                        PageThumbnail(page: page, number: number + 1)
                    }
                    if draft.pending > 0 {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.ink.opacity(0.05))
                            .frame(width: 150, height: 200)
                            .overlay(ProgressView().controlSize(.small))
                    }
                    AddPageTile()
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 8)
                // Centered while the pages fit; scrolls once they don't.
                .frame(minWidth: geo.size.width)
            }
            }
            .frame(height: 230)

            HStack(spacing: 12) {
                Text(draft.pages.count == 1 ? "1 page" : "\(draft.pages.count) pages")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink.opacity(0.4))
                Button(action: draft.read) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                        Text("Read")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.accent))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.pages.isEmpty || draft.pending > 0)
                .opacity(draft.pages.isEmpty || draft.pending > 0 ? 0.5 : 1)
                .help("Read these pages  ⌘↩")
            }
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { Self.add(file: url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { ScanDraft.shared.add(images: [data]) }
                }
            }
        }
        return handled
    }

    private static func add(file url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            if let data = try? Data(contentsOf: url) { ScanDraft.shared.add(pdf: data) }
        } else if type?.conforms(to: .image) == true, let data = try? Data(contentsOf: url) {
            ScanDraft.shared.add(images: [data])
        } else {
            // Not a page: read it the usual way.
            LibraryState.shared.scanning = false
            ReadingCoordinator.shared.open([url])
        }
    }
}

/// Opens the Continuity Camera menu.
private struct CameraButton: View {
    let title: String
    var prominent = false
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { ScanDraft.shared.camera?.showMenu() } label: {
            HStack(spacing: 6) {
                Image(systemName: "iphone").font(.system(size: 12))
                Text(title)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.white : theme.ink.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(prominent ? theme.accent.opacity(hovering ? 1 : 0.9) : theme.ink.opacity(hovering ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(CameraAnchor())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Take a photo or scan pages with your iPhone or iPad")
    }
}

private struct AddPageTile: View {
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { ScanDraft.shared.camera?.showMenu() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 22, weight: .light))
                Text("Add page").font(.system(size: 11.5))
            }
            .foregroundStyle(theme.ink.opacity(hovering ? 0.9 : 0.55))
            .frame(width: 150, height: 200)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.ink.opacity(hovering ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(CameraAnchor())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Add another page with your iPhone, or drop one here")
    }
}

private struct PageThumbnail: View {
    let page: ScanDraft.Page
    let number: Int
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Image(nsImage: page.thumbnail)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 150, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.ink.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .overlay(alignment: .bottomLeading) {
                Text("\(number)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(7)
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { ScanDraft.shared.remove(page.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Remove this page")
                }
            }
            .onHover { hovering = $0 }
    }
}
