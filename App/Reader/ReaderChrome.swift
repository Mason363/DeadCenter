import SwiftUI
import DCEngine

/// State and actions the bottom chrome needs from the reader.
@Observable
final class ReaderChromeModel {
    var session: ReaderSession?
    var palette: ReaderPalette = .dark
    /// "Title — Chapter".
    var title = ""
    /// "42%  ·  12 min left", refreshed by the reader about once a second.
    var timeText = ""
    /// Words at the hovered timeline position; replaces the info line while set.
    var previewText: String?

    @ObservationIgnored var onSeek: (Double) -> Void = { _ in }
    @ObservationIgnored var onScrubbing: (Bool) -> Void = { _ in }
    @ObservationIgnored var onHover: (Double?) -> Void = { _ in }
    @ObservationIgnored var onSpeedChange: (Int) -> Void = { _ in }
}

/// The reader's quiet bottom edge: one info line and a thin timeline. Speed buttons and the
/// timeline knob only appear when the pointer comes near.
struct ReaderChrome: View {
    let model: ReaderChromeModel
    @State private var near = false

    private var text: Color { Color(nsColor: model.palette.text) }
    private var background: Color { Color(nsColor: model.palette.background) }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if let preview = model.previewText {
                    Text(preview)
                        .foregroundStyle(text.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                } else {
                    infoLine.transition(.opacity)
                }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .frame(height: 22)
            .padding(.horizontal, 40)

            TimelineTrack(model: model, near: near)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(
            // Lets page text scroll softly underneath; invisible over the reader's own background.
            LinearGradient(colors: [background.opacity(0), background.opacity(0.94), background],
                           startPoint: .top, endPoint: .bottom)
        )
        .contentShape(Rectangle())
        .onHover { near = $0 }
        .animation(.smooth(duration: 0.22), value: model.previewText == nil)
        .animation(.smooth(duration: 0.25), value: near)
    }

    private var infoLine: some View {
        HStack(spacing: 0) {
            if !model.title.isEmpty {
                Text(model.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                separator
            }
            if !model.timeText.isEmpty {
                Text(model.timeText).fixedSize()
                // The menu button brings a little padding of its own.
                Text("  ·").fixedSize()
            }
            SpeedControl(model: model, expanded: near)
        }
        .foregroundStyle(text.opacity(0.45))
    }

    private var separator: some View {
        Text("  ·  ").fixedSize()
    }
}

private struct SpeedControl: View {
    let model: ReaderChromeModel
    let expanded: Bool
    private let presets = [150, 200, 250, 300, 350, 400, 450, 500, 600, 700, 800, 1000]

    var body: some View {
        let wpm = Preferences.shared.wpm
        let text = Color(nsColor: model.palette.text)
        HStack(spacing: 0) {
            // Always laid out, only faded, so the line never shifts when they appear.
            StepButton(symbol: "minus", help: "Slower  ↓", visible: expanded) { model.onSpeedChange(-25) }
            Menu {
                ForEach(presets, id: \.self) { value in
                    Button {
                        model.onSpeedChange(value - Preferences.shared.wpm)
                    } label: {
                        if value == wpm { Label("\(value) wpm", systemImage: "checkmark") } else { Text("\(value) wpm") }
                    }
                }
                Divider()
                Toggle("Adaptive Speed", isOn: Binding(get: { Preferences.shared.adaptiveSpeed },
                                                       set: { Preferences.shared.adaptiveSpeed = $0 }))
            } label: {
                Text("\(wpm) wpm")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(text.opacity(expanded ? 0.85 : 0.45))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reading speed — click for presets")
            StepButton(symbol: "plus", help: "Faster  ↑", visible: expanded) { model.onSpeedChange(25) }
        }
    }
}

private struct StepButton: View {
    let symbol: String
    let help: String
    let visible: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? (hovering ? 1 : 0.5) : 0)
        .allowsHitTesting(visible)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A thin line that's easy to hit: a tall invisible target that thickens a little when the
/// pointer is near, with a faint preview of where a click would land.
private struct TimelineTrack: View {
    let model: ReaderChromeModel
    let near: Bool
    @State private var hoverFraction: Double?
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let progress = min(max(model.session?.progress ?? 0, 0), 1)
            let active = hoverFraction != nil || dragging
            let thickness: CGFloat = active ? 4 : (near ? 3 : 2)
            let text = Color(nsColor: model.palette.text)
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(text.opacity(near || active ? 0.09 : 0)).frame(height: thickness)
                if let hover = hoverFraction, !dragging {
                    Rectangle().fill(text.opacity(0.12)).frame(width: width * hover, height: thickness)
                }
                Rectangle().fill(text.opacity(active ? 0.55 : 0.3)).frame(width: width * progress, height: thickness)
                ForEach(chapterFractions, id: \.self) { fraction in
                    Rectangle().fill(text.opacity(0.35))
                        .frame(width: 1, height: thickness + 3)
                        .offset(x: width * fraction)
                        .opacity(near || active ? 1 : 0)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .bottomLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let fraction = min(max(location.x / width, 0), 1)
                    hoverFraction = fraction
                    model.onHover(fraction)
                case .ended:
                    hoverFraction = nil
                    if !dragging { model.onHover(nil) }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            model.onScrubbing(true)
                        }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        model.onSeek(fraction)
                        model.onHover(fraction)
                    }
                    .onEnded { _ in
                        dragging = false
                        model.onScrubbing(false)
                        if hoverFraction == nil { model.onHover(nil) }
                    }
            )
            .animation(.smooth(duration: 0.2), value: active)
            .animation(.smooth(duration: 0.2), value: near)
        }
        .frame(height: 20)
    }

    private var chapterFractions: [Double] {
        guard let stream = model.session?.stream, stream.count > 1, stream.chapters.count > 1 else { return [] }
        let total = Double(stream.count - 1)
        return stream.chapters.prefix(200).map { Double($0.itemIndex) / total }
    }
}

/// A clean × that fades in when the pointer reaches the window's top-left corner,
/// sitting where the corner's curve has room for it.
struct CloseButton: View {
    let palette: ReaderPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(nsColor: palette.text).opacity(hovering ? 0.95 : 0.55))
                .scaleEffect(hovering ? 1.08 : 1)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .frame(width: 30, height: 30)
        .ignoresSafeArea()
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close  Esc")
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
