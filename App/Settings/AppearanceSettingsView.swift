import AppKit
import SwiftUI

struct AppearanceSettingsView: View {
    @Bindable private var prefs = Preferences.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ReaderPreview()
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.08), lineWidth: 1))
                .accessibilityLabel("Live preview")

            SettingsSection(title: "Colors") {
                SettingsRow(title: "Theme") {
                    DCSegmented(selection: $prefs.appearance, options: AppearanceMode.allCases.map { ($0, $0.label) })
                }
                RowDivider()
                SettingsRow(title: "Colors") {
                    HStack(spacing: 10) {
                        well(\.customBackgroundHex) { $0.background }
                        well(\.customTextHex) { $0.text }
                        well(\.customPivotHex) { $0.pivot }
                    }
                }
            }

            SettingsSection(title: "Type") {
                SettingsRow(title: "Font") {
                    FontPopUp(selection: $prefs.fontFamily)
                        .frame(width: 210)
                }
                RowDivider()
                SettingsRow(title: "Weight") {
                    DCSegmented(selection: weight, options: FontWeightOption.allCases.map { ($0, $0.shortLabel) })
                }
                RowDivider()
                SettingsRow(title: "Text size") {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.size.smaller").font(.system(size: 11)).foregroundStyle(theme.ink.opacity(0.4))
                        DCSlider(value: $prefs.textScale, range: Preferences.textScaleRange, width: 150)
                        Image(systemName: "textformat.size.larger").font(.system(size: 13)).foregroundStyle(theme.ink.opacity(0.4))
                    }
                }
                RowDivider()
                SettingsRow(title: "Bold focus letter") {
                    DCToggle(isOn: $prefs.boldPivot)
                }
                RowDivider()
                SettingsRow(title: "Guide ticks") {
                    DCToggle(isOn: $prefs.showGuides)
                }
            }

            SettingsSection(title: "Window") {
                SettingsRow(title: "Progress line") {
                    DCSegmented(selection: $prefs.progressVisibility,
                                options: ProgressVisibility.allCases.map { ($0, $0 == .paused ? "Paused" : $0.label) })
                }
                if #available(macOS 26, *) {
                    RowDivider()
                    SettingsRow(title: "Material") {
                        DCSegmented(selection: $prefs.material, options: PanelMaterial.allCases.map { ($0, $0.label) })
                    }
                }
            }

            HStack {
                Spacer()
                DCButton(title: "Reset to Defaults", action: reset)
            }
        }
    }

    private var palette: ReaderPalette { prefs.palette(systemIsDark: colorScheme == .dark) }

    private var weight: Binding<FontWeightOption> {
        Binding(get: { FontWeightOption.nearest(to: prefs.fontWeight) },
                set: { prefs.fontWeight = $0.value })
    }

    /// A color well that always shows the color in use; editing one starts a Custom palette.
    private func well(_ key: ReferenceWritableKeyPath<Preferences, String>,
                      _ value: @escaping (ReaderPalette) -> NSColor) -> some View {
        ColorPicker("", selection: Binding(
            get: { Color(nsColor: value(palette)) },
            set: { color in
                if prefs.appearance != .custom {
                    let current = palette
                    prefs.customBackgroundHex = current.background.hexString
                    prefs.customTextHex = current.text.hexString
                    prefs.customPivotHex = current.pivot.hexString
                    prefs.appearance = .custom
                }
                prefs[keyPath: key] = NSColor(color).hexString
            }), supportsOpacity: false)
            .labelsHidden()
            .fixedSize()
    }

    private func reset() {
        prefs.resetAppearance()
        let dark = ReaderPalette.dark
        prefs.customBackgroundHex = dark.background.hexString
        prefs.customTextHex = dark.text.hexString
        prefs.customPivotHex = dark.pivot.hexString
    }
}

/// A font menu where every family's name is drawn in that family, so you can see it before choosing.
private struct FontPopUp: NSViewRepresentable {
    @Binding var selection: String

    /// Installed families, minus hidden system ones (".SF NS" and friends).
    private static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    private static let size: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        let menu = button.menu ?? NSMenu()
        menu.addItem(Self.item(title: "System (SF Pro)", family: "", font: .systemFont(ofSize: Self.size)))
        menu.addItem(.separator())
        for family in Self.families {
            menu.addItem(Self.item(title: family, family: family, font: Self.previewFont(family)))
        }
        select(selection, in: button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        select(selection, in: button)
    }

    /// The menu's natural width is its longest font name; take the width SwiftUI offers instead.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 210, height: nsView.intrinsicContentSize.height)
    }

    private func select(_ family: String, in button: NSPopUpButton) {
        if let item = button.itemArray.first(where: { ($0.representedObject as? String) == family }) {
            if button.selectedItem !== item { button.select(item) }
        } else if !family.isEmpty {
            // A family that's no longer installed: keep showing it.
            let item = Self.item(title: family, family: family, font: .systemFont(ofSize: Self.size))
            button.menu?.insertItem(item, at: 2)
            button.select(item)
        }
    }

    private static func item(title: String, family: String, font: NSFont) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        item.representedObject = family
        return item
    }

    /// The family's regular face, or the system font for symbol fonts whose letters aren't letters.
    private static func previewFont(_ family: String) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        guard let font = NSFont(descriptor: descriptor, size: size) else { return .systemFont(ofSize: size) }
        let traits = CTFontGetSymbolicTraits(font as CTFont).rawValue
        let isSymbolic = traits & CTFontSymbolicTraits.traitClassMask.rawValue
            == CTFontStylisticClass.symbolicClass.rawValue
        let coversLatin = font.coveredCharacterSet.isSuperset(of: CharacterSet(charactersIn: "AaBbGg"))
        return isSymbolic || !coversLatin ? .systemFont(ofSize: size) : font
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>

        init(selection: Binding<String>) {
            self.selection = selection
        }

        @objc func changed(_ sender: NSPopUpButton) {
            selection.wrappedValue = sender.selectedItem?.representedObject as? String ?? ""
        }
    }
}

private enum FontWeightOption: CaseIterable, Identifiable {
    case light, regular, medium, semibold, bold

    var id: Self { self }

    /// NSFont.Weight raw value, as stored in Preferences.
    var value: Double {
        let weight: NSFont.Weight = switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        return Double(weight.rawValue)
    }

    var label: String { "\(self)".capitalized }
    var shortLabel: String { self == .semibold ? "Semi" : label }

    static func nearest(to value: Double) -> Self {
        allCases.min { abs($0.value - value) < abs($1.value - value) } ?? .medium
    }
}
