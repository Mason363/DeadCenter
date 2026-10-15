import AppKit
import Observation

enum PivotMode: String, CaseIterable, Identifiable {
    case optimal, middle
    var id: Self { self }
    var label: String { self == .optimal ? "Optimal point" : "Middle letter" }
}

enum Pacing: String, CaseIterable, Identifiable {
    case even, natural, relaxed
    var id: Self { self }
    var label: String { rawValue.capitalized }
    /// Scale applied to the engine's extra pause weights.
    var strength: Double {
        switch self {
        case .even: 0
        case .natural: 1
        case .relaxed: 1.6
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system, custom
    var id: Self { self }
    var label: String { self == .system ? "Auto" : rawValue.capitalized }
}

enum ProgressVisibility: String, CaseIterable, Identifiable {
    case always, paused, never
    var id: Self { self }
    var label: String {
        switch self {
        case .always: "Always"
        case .paused: "When paused"
        case .never: "Never"
        }
    }
}

enum PanelMaterial: String, CaseIterable, Identifiable {
    case solid, glass
    var id: Self { self }
    var label: String { rawValue.capitalized }
}

enum WindowSizePreset: Int, CaseIterable, Identifiable {
    case compact = 1, regular, large
    var id: Self { self }
    var label: String {
        switch self {
        case .compact: "Compact"
        case .regular: "Regular"
        case .large: "Large"
        }
    }
    /// Content size before clamping to the screen.
    var size: NSSize {
        switch self {
        case .compact: NSSize(width: 620, height: 168)
        case .regular: NSSize(width: 860, height: 300)
        case .large: NSSize(width: 1180, height: 520)
        }
    }
}

/// Resolved colors for the reader surface.
struct ReaderPalette: Equatable {
    var background: NSColor
    var text: NSColor
    var pivot: NSColor

    static let dark = ReaderPalette(
        background: NSColor(hex: "#000000")!, text: NSColor(hex: "#EDEDED")!, pivot: NSColor(hex: "#FF3B30")!)
    static let light = ReaderPalette(
        background: NSColor(hex: "#FFFFFF")!, text: NSColor(hex: "#111111")!, pivot: NSColor(hex: "#E0301E")!)
}

/// Every user setting, persisted in UserDefaults. Observable so SwiftUI and the reader update live.
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults: UserDefaults

    // Reading
    var wpm: Int { didSet { defaults.set(wpm, forKey: Key.wpm) } }
    var pivotMode: PivotMode { didSet { defaults.set(pivotMode.rawValue, forKey: Key.pivotMode) } }
    var pacing: Pacing { didSet { defaults.set(pacing.rawValue, forKey: Key.pacing) } }
    /// Adapt speed to the text: denser passages and harder documents read slower, easy ones faster.
    var adaptiveSpeed: Bool { didSet { defaults.set(adaptiveSpeed, forKey: Key.adaptiveSpeed) } }
    var easeIn: Bool { didSet { defaults.set(easeIn, forKey: Key.easeIn) } }
    var resumeAtSentence: Bool { didSet { defaults.set(resumeAtSentence, forKey: Key.resumeAtSentence) } }
    var autoStart: Bool { didSet { defaults.set(autoStart, forKey: Key.autoStart) } }
    var showImages: Bool { didSet { defaults.set(showImages, forKey: Key.showImages) } }
    /// Seconds an image beat stays up. 0 means "until I continue".
    var imageDuration: Double { didSet { defaults.set(imageDuration, forKey: Key.imageDuration) } }

    // Appearance
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    var customBackgroundHex: String { didSet { defaults.set(customBackgroundHex, forKey: Key.customBackground) } }
    var customTextHex: String { didSet { defaults.set(customTextHex, forKey: Key.customText) } }
    var customPivotHex: String { didSet { defaults.set(customPivotHex, forKey: Key.customPivot) } }
    /// Font family name, or "" for the system font (SF Pro).
    var fontFamily: String { didSet { defaults.set(fontFamily, forKey: Key.fontFamily) } }
    /// NSFont.Weight raw value.
    var fontWeight: Double { didSet { defaults.set(fontWeight, forKey: Key.fontWeight) } }
    /// Multiplier on the automatic, window-relative text size.
    var textScale: Double { didSet { defaults.set(textScale, forKey: Key.textScale) } }
    var boldPivot: Bool { didSet { defaults.set(boldPivot, forKey: Key.boldPivot) } }
    var showGuides: Bool { didSet { defaults.set(showGuides, forKey: Key.showGuides) } }
    var progressVisibility: ProgressVisibility { didSet { defaults.set(progressVisibility.rawValue, forKey: Key.progress) } }
    var material: PanelMaterial { didSet { defaults.set(material.rawValue, forKey: Key.material) } }

    // Window
    var windowSize: WindowSizePreset { didSet { defaults.set(windowSize.rawValue, forKey: Key.windowSize) } }

    // General
    var rememberHistory: Bool { didSet { defaults.set(rememberHistory, forKey: Key.rememberHistory) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarded) } }

    static let wpmRange = 100...1500
    static let textScaleRange = 0.6...1.6

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.wpm: 350,
            Key.pivotMode: PivotMode.optimal.rawValue,
            Key.pacing: Pacing.natural.rawValue,
            Key.adaptiveSpeed: false,
            Key.easeIn: true,
            Key.resumeAtSentence: true,
            Key.autoStart: true,
            Key.showImages: true,
            Key.imageDuration: 10.0,
            Key.appearance: AppearanceMode.dark.rawValue,
            Key.customBackground: "#000000",
            Key.customText: "#EDEDED",
            Key.customPivot: "#FF3B30",
            Key.fontFamily: "",
            Key.fontWeight: Double(NSFont.Weight.medium.rawValue),
            Key.textScale: 1.0,
            Key.boldPivot: false,
            Key.showGuides: false,
            Key.progress: ProgressVisibility.paused.rawValue,
            Key.material: PanelMaterial.solid.rawValue,
            Key.windowSize: WindowSizePreset.regular.rawValue,
            Key.rememberHistory: true,
            Key.onboarded: false,
        ])
        wpm = defaults.integer(forKey: Key.wpm)
        pivotMode = PivotMode(rawValue: defaults.string(forKey: Key.pivotMode) ?? "") ?? .optimal
        pacing = Pacing(rawValue: defaults.string(forKey: Key.pacing) ?? "") ?? .natural
        adaptiveSpeed = defaults.bool(forKey: Key.adaptiveSpeed)
        easeIn = defaults.bool(forKey: Key.easeIn)
        resumeAtSentence = defaults.bool(forKey: Key.resumeAtSentence)
        autoStart = defaults.bool(forKey: Key.autoStart)
        showImages = defaults.bool(forKey: Key.showImages)
        imageDuration = defaults.double(forKey: Key.imageDuration)
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .dark
        customBackgroundHex = defaults.string(forKey: Key.customBackground) ?? "#000000"
        customTextHex = defaults.string(forKey: Key.customText) ?? "#EDEDED"
        customPivotHex = defaults.string(forKey: Key.customPivot) ?? "#FF3B30"
        fontFamily = defaults.string(forKey: Key.fontFamily) ?? ""
        fontWeight = defaults.double(forKey: Key.fontWeight)
        textScale = defaults.double(forKey: Key.textScale)
        boldPivot = defaults.bool(forKey: Key.boldPivot)
        showGuides = defaults.bool(forKey: Key.showGuides)
        progressVisibility = ProgressVisibility(rawValue: defaults.string(forKey: Key.progress) ?? "") ?? .paused
        material = PanelMaterial(rawValue: defaults.string(forKey: Key.material) ?? "") ?? .solid
        windowSize = WindowSizePreset(rawValue: defaults.integer(forKey: Key.windowSize)) ?? .regular
        rememberHistory = defaults.bool(forKey: Key.rememberHistory)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarded)
    }

    /// Colors for the current appearance. `dark` decides `.system`.
    func palette(systemIsDark: Bool) -> ReaderPalette {
        switch appearance {
        case .dark: .dark
        case .light: .light
        case .system: systemIsDark ? .dark : .light
        case .custom:
            ReaderPalette(
                background: NSColor(hex: customBackgroundHex) ?? .black,
                text: NSColor(hex: customTextHex) ?? .white,
                pivot: NSColor(hex: customPivotHex) ?? .systemRed)
        }
    }

    /// The reading font at a point size.
    func font(size: CGFloat, bold: Bool = false) -> NSFont {
        let weight = NSFont.Weight(rawValue: bold ? max(CGFloat(fontWeight), NSFont.Weight.bold.rawValue) : CGFloat(fontWeight))
        if fontFamily.isEmpty {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: fontFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    func resetAppearance() {
        appearance = .dark
        fontFamily = ""
        fontWeight = Double(NSFont.Weight.medium.rawValue)
        textScale = 1.0
        boldPivot = false
        showGuides = false
        progressVisibility = .paused
        material = .solid
    }

    private enum Key {
        static let wpm = "wpm"
        static let pivotMode = "pivotMode"
        static let pacing = "pacing"
        static let adaptiveSpeed = "adaptiveSpeed"
        static let easeIn = "easeIn"
        static let resumeAtSentence = "resumeAtSentence"
        static let autoStart = "autoStart"
        static let showImages = "showImages"
        static let imageDuration = "imageDuration"
        static let appearance = "appearance"
        static let customBackground = "customBackground"
        static let customText = "customText"
        static let customPivot = "customPivot"
        static let fontFamily = "fontFamily"
        static let fontWeight = "fontWeight"
        static let textScale = "textScale"
        static let boldPivot = "boldPivot"
        static let showGuides = "showGuides"
        static let progress = "progressVisibility"
        static let material = "material"
        static let windowSize = "windowSize"
        static let rememberHistory = "rememberHistory"
        static let onboarded = "hasCompletedOnboarding"
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
