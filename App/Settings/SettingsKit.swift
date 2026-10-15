import AppKit
import SwiftUI

/// Colors for Settings and the Library, taken from the reader's palette.
struct SettingsTheme {
    var ink: Color
    var accent: Color
    var background: Color

    init(_ palette: ReaderPalette) {
        ink = Color(nsColor: palette.text)
        accent = Color(nsColor: palette.pivot)
        background = Color(nsColor: palette.background)
    }
}

extension EnvironmentValues {
    @Entry var settingsTheme = SettingsTheme(.dark)
}

/// Keeps a window's light/dark look in step with the reader palette, so native controls
/// (shortcut recorder, menus, color wells) match the custom surfaces around them.
enum WindowTheming {
    static func track(_ window: NSWindow) {
        apply(to: window)
        withObservationTracking {
            _ = Preferences.shared.appearance
            _ = Preferences.shared.customBackgroundHex
        } onChange: { [weak window] in
            DispatchQueue.main.async {
                guard let window else { return }
                track(window)
            }
        }
    }

    static func apply(to window: NSWindow) {
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = Preferences.shared.palette(systemIsDark: systemDark)
        window.appearance = NSAppearance(named: isDark(palette.background) ? .darkAqua : .aqua)
        window.backgroundColor = palette.background
    }

    static func isDark(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return true }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }
}

// MARK: - Layout

/// A titled group of rows on a soft rounded surface.
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(theme.ink.opacity(0.38))
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.ink.opacity(0.04)))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.ink.opacity(0.38))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A label with an optional quiet hint, and its control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control
    @Environment(\.settingsTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink.opacity(0.88))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.ink.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct RowDivider: View {
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.ink.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

// MARK: - Controls

/// A capsule switch in the reader's accent color.
struct DCToggle: View {
    @Binding var isOn: Bool
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? theme.accent : theme.ink.opacity(0.15))
                    .frame(width: 34, height: 20)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }
}

/// Segments with a highlight that slides to the choice.
struct DCSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Environment(\.settingsTheme) private var theme
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(theme.ink.opacity(selected ? 0.95 : 0.5))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(theme.ink.opacity(0.13))
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(theme.ink.opacity(0.05)))
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].label).tag(options[$0].value) }
            }
        }
    }
}

/// A thin slider with a soft knob.
struct DCSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var width: CGFloat = 190
    @Environment(\.settingsTheme) private var theme
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            let knob: CGFloat = dragging ? 16 : 14
            ZStack(alignment: .leading) {
                Capsule().fill(theme.ink.opacity(0.12)).frame(height: 3)
                Capsule().fill(theme.ink.opacity(0.55)).frame(width: geo.size.width * fraction, height: 3)
                Circle()
                    .fill(theme.ink)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .offset(x: (geo.size.width - knob) * fraction)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        set(Double(drag.location.x / max(geo.size.width, 1)))
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(width: width, height: 22)
        .accessibilityRepresentation { Slider(value: $value, in: range) }
    }

    private func set(_ fraction: Double) {
        var v = range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound)
        if let step { v = (v / step).rounded() * step }
        value = min(max(v, range.lowerBound), range.upperBound)
    }
}

/// A quiet capsule button.
struct DCButton: View {
    let title: String
    var destructive = false
    let action: () -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(destructive ? theme.accent : theme.ink.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.ink.opacity(hovering ? 0.12 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A small status line with a colored dot.
struct StatusLabel: View {
    let text: String
    let color: Color
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(theme.ink.opacity(0.5))
        }
    }
}

extension View {
    /// The quiet explanatory line under a settings section.
    func settingsFootnote() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
