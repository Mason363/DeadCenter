import Foundation
import Observation
import WhisperKit

nonisolated enum AudioSource: String, CaseIterable, Identifiable, Sendable {
    case microphone, system, both

    var id: Self { self }

    var label: String {
        switch self {
        case .microphone: "Mic"
        case .system: "System"
        case .both: "Both"
        }
    }

    var settingsLabel: String {
        switch self {
        case .microphone: "Microphone"
        case .system: "System audio"
        case .both: "Microphone and system audio"
        }
    }

    var usesMicrophone: Bool { self != .system }
    var usesSystemAudio: Bool { self != .microphone }
}

/// Transcription settings, persisted in UserDefaults.
@Observable
final class TranscriptionPreferences {
    static let shared = TranscriptionPreferences()

    @ObservationIgnored private let defaults: UserDefaults

    var model: ModelTier { didSet { defaults.set(model.rawValue, forKey: Key.model) } }
    /// A Whisper language code, or "" to detect it.
    var language: String { didSet { defaults.set(language, forKey: Key.language) } }
    var translate: Bool { didSet { defaults.set(translate, forKey: Key.translate) } }
    var source: AudioSource { didSet { defaults.set(source.rawValue, forKey: Key.source) } }
    /// Core Audio UID of the chosen input, or "" for the system default.
    var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: Key.inputDevice) } }
    var floatsOnTop: Bool { didSet { defaults.set(floatsOnTop, forKey: Key.floatsOnTop) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = ModelTier(rawValue: defaults.string(forKey: Key.model) ?? "") ?? ModelStore.shared.recommended
        language = defaults.string(forKey: Key.language) ?? ""
        translate = defaults.bool(forKey: Key.translate)
        source = AudioSource(rawValue: defaults.string(forKey: Key.source) ?? "") ?? .microphone
        inputDeviceUID = defaults.string(forKey: Key.inputDevice) ?? ""
        floatsOnTop = defaults.bool(forKey: Key.floatsOnTop)
    }

    var decodingOptions: DecodingOptions {
        .deadCenter(language: language.isEmpty ? nil : language, translate: translate)
    }

    /// Whisper's languages by localized name.
    static let languages: [(code: String, name: String)] = Set(Constants.languages.values)
        .map { code in
            let fallback = Constants.languages.first { $0.value == code }?.key.capitalized ?? code
            return (code, Locale.current.localizedString(forLanguageCode: code) ?? fallback)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private enum Key {
        static let model = "transcriptionModel"
        static let language = "transcriptionLanguage"
        static let translate = "transcriptionTranslate"
        static let source = "transcriptionSource"
        static let inputDevice = "transcriptionInputDevice"
        static let floatsOnTop = "transcriptionFloatsOnTop"
    }
}
