import Foundation
@preconcurrency import WhisperKit

/// Owns the loaded Whisper model. Loading and inference run off the main thread; callers make
/// sure only one transcription runs at a time.
actor WhisperService {
    static let shared = WhisperService()

    private var current: (variant: String, task: Task<WhisperKit, Error>)?

    var loadedVariant: String? { current?.variant }

    init() {
        Logging.shared.logLevel = .none
    }

    /// Loads a downloaded model, replacing any other. Concurrent calls for the same model share one load.
    func load(variant: String, folder: URL) async throws {
        if let current, current.variant == variant {
            _ = try await current.task.value
            return
        }
        await unload()
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: ModelStore.baseURL,
            verbose: false,
            logLevel: .none,
            // Compiles each part on its own first, which keeps peak memory low on a cold cache.
            prewarm: true,
            load: true,
            download: false)
        let task = Task { try await WhisperKit(config) }
        current = (variant, task)
        do {
            _ = try await task.value
        } catch {
            if current?.variant == variant { current = nil }
            throw error
        }
    }

    func unload() async {
        guard let current else { return }
        self.current = nil
        if let kit = try? await current.task.value {
            await kit.unloadModels()
        }
    }

    func unload(ifVariant variant: String) async {
        if current?.variant == variant { await unload() }
    }

    /// Text tokens for conditioning the next pass on what was just said.
    func tokens(for text: String) async -> [Int]? {
        guard let kit = try? await current?.task.value, let tokenizer = kit.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + text.trimmingCharacters(in: .whitespaces))
        return tokens.filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }

    /// Several pieces of up to 30 s, run side by side; results come back in order.
    func transcribe(pieces: [[Float]], options: DecodingOptions) async throws -> [[TranscriptionResult]] {
        guard let current else { throw WhisperError.modelsUnavailable("No model is loaded.") }
        let kit = try await current.task.value
        let results = await kit.transcribeWithResults(audioArrays: pieces, decodeOptions: options)
        try Task.checkCancellation()
        return try results.map { try $0.get() }
    }

    func transcribe(_ samples: [Float], options: DecodingOptions) async throws -> [TranscriptionResult] {
        guard let current else { throw WhisperError.modelsUnavailable("No model is loaded.") }
        let kit = try await current.task.value
        return try await kit.transcribe(audioArray: samples, decodeOptions: options)
    }
}

extension DecodingOptions {
    /// Shared settings for live and file transcription.
    nonisolated static func deadCenter(language: String?, translate: Bool) -> DecodingOptions {
        DecodingOptions(
            task: translate ? .translate : .transcribe,
            language: language,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            suppressBlank: true,
            // WhisperKit's early exit on an unsure first word drops whole 30 s windows of real
            // speech; silence is already kept away by the speech gating.
            firstTokenLogProbThreshold: nil,
            concurrentWorkerCount: 4)
    }
}

extension TranscriptionSegment {
    /// Whisper's text cleaned up, or nil for silence markers and likely hallucinations.
    nonisolated var spokenText: String? {
        let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if noSpeechProb > 0.6 && avgLogprob < -1 { return nil }
        // Whisper stuck repeating itself within this segment.
        if text.count > 40 && TextUtilities.compressionRatio(of: text) > 2.4 { return nil }
        // Annotations such as [BLANK_AUDIO], (music) or ♪ ♪.
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("*", "*"), ("♪", "♪")]
        if pairs.contains(where: { text.first == $0.0 && text.last == $0.1 }) { return nil }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }
}
