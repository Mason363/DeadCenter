import AppKit
import SwiftUI
import ImageIO
import DCModel
import DCEngine

/// Decodes image beats off the main thread and keeps a small cache around the reading position.
final class ImageLoader {
    private var cache: [Int: CGImage] = [:]
    private var loading: Set<Int> = []
    private var waiters: [Int: [(CGImage?) -> Void]] = [:]
    private var generation = 0

    func reset() {
        cache = [:]
        loading = []
        waiters = [:]
        generation += 1
    }

    func cached(_ index: Int) -> CGImage? { cache[index] }

    func load(_ asset: ImageAsset, index: Int, completion: @escaping (CGImage?) -> Void) {
        if let image = cache[index] { return completion(image) }
        waiters[index, default: []].append(completion)
        guard !loading.contains(index) else { return }
        loading.insert(index)
        let generation = generation
        Task {
            let image = await Self.decode(asset).map(\.image)
            guard generation == self.generation else { return }
            loading.remove(index)
            if let image {
                cache[index] = image
                trim(around: index)
            }
            waiters.removeValue(forKey: index)?.forEach { $0(image) }
        }
    }

    /// Starts decoding the next few images so they're ready when their beat arrives.
    func preload(_ stream: ReadingStream, from index: Int) {
        guard Preferences.shared.showImages, !stream.isEmpty else { return }
        let end = min(stream.count, index + 60)
        var found = 0
        var i = max(index, 0)
        while i < end, found < 3 {
            if let asset = stream[i].image {
                found += 1
                if cache[i] == nil, !loading.contains(i) { load(asset, index: i) { _ in } }
            }
            i += 1
        }
    }

    private func trim(around index: Int) {
        guard cache.count > 8 else { return }
        for key in cache.keys.sorted(by: { abs($0 - index) > abs($1 - index) }).prefix(cache.count - 8) {
            cache.removeValue(forKey: key)
        }
    }

    struct Decoded: @unchecked Sendable { let image: CGImage }

    @concurrent
    nonisolated static func decode(_ asset: ImageAsset) async -> Decoded? {
        let data: Data?
        switch asset.source {
        case .data(let d):
            data = d
        case .url(let url):
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await URLSession.shared.data(from: url).0
            }
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2800,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Decoded.init)
    }
}

/// The `?` overlay: every reader shortcut, in two quiet columns.
struct ShortcutsOverlay: View {
    let background: Color
    let foreground: Color
    let accent: Color

    private let left: [(String, String)] = [
        ("Space", "Play / pause"),
        ("← →", "Back / forward"),
        ("⌥ ← →", "Paragraph"),
        ("↑ ↓", "Speed"),
        ("Tab", "Page view"),
        ("⌘F", "Find a word"),
    ]
    private let right: [(String, String)] = [
        ("F", "Full screen"),
        ("⌘ 1 2 3", "Window size"),
        ("⌘ + −", "Text size"),
        ("⌘ [ ]", "Chapter"),
        ("⌘E", "Edit text"),
        ("Swipe", "Scrub · bottom edge jumps"),
    ]

    var body: some View {
        ZStack {
            background.opacity(0.96)
            HStack(alignment: .top, spacing: 44) {
                column(left)
                column(right)
            }
            .padding(18)
        }
    }

    private func column(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { keys, action in
                GridRow {
                    Text(keys)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(foreground)
                        .gridColumnAlignment(.trailing)
                    Text(action)
                        .font(.system(size: 12))
                        .foregroundStyle(foreground.opacity(0.55))
                }
            }
        }
    }
}
