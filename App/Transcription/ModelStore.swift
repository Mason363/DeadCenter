import Foundation
import Observation
import WhisperKit

/// The three speech models on offer, each a Core ML Whisper build from argmaxinc/whisperkit-coreml.
nonisolated enum ModelTier: String, CaseIterable, Identifiable, Sendable {
    case fast, balanced, accurate

    var id: Self { self }

    var title: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .accurate: "Accurate"
        }
    }

    var modelName: String {
        switch self {
        case .fast: "Whisper Base"
        case .balanced: "Whisper Small"
        case .accurate: "Whisper Large v3 Turbo"
        }
    }

    /// Builds in order of preference; the first one WhisperKit lists as supported on this Mac wins.
    fileprivate var candidates: [ModelBuild] {
        switch self {
        case .fast:
            [ModelBuild(variant: "openai_whisper-base", bytes: 146_719_453)]
        case .balanced:
            [ModelBuild(variant: "openai_whisper-small", bytes: 486_487_465)]
        case .accurate:
            [ModelBuild(variant: "openai_whisper-large-v3-v20240930_turbo_632MB", bytes: 645_668_913),
             ModelBuild(variant: "openai_whisper-large-v3-v20240930_626MB", bytes: 626_718_238)]
        }
    }

    /// "147 MB", "1.6 GB".
    static func size(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        return megabytes < 1000 ? "\(Int(megabytes.rounded())) MB" : String(format: "%.1f GB", megabytes / 1000)
    }

    /// The Hugging Face tokenizer that matches the model's vocabulary.
    var tokenizer: ModelVariant {
        switch self {
        case .fast: .base
        case .balanced: .small
        case .accurate: .largev3
        }
    }
}

nonisolated struct ModelBuild: Hashable, Sendable {
    let variant: String
    /// Download size, for display before the exact file list is fetched.
    let bytes: Int64
}

/// Downloads, verifies and deletes models in ~/Library/Application Support/Dead Center/Models.
@Observable
final class ModelStore {
    static let shared = ModelStore()

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case failed(String)
    }

    private(set) var installed: Set<ModelTier> = []
    private(set) var phases: [ModelTier: Phase] = [:]
    let recommended: ModelTier

    @ObservationIgnored private var downloads: [ModelTier: Task<Void, Never>] = [:]
    private let supported: Set<String>

    static let repo = "argmaxinc/whisperkit-coreml"

    nonisolated static let baseURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Dead Center/Models", directoryHint: .isDirectory)
    }()

    /// Where the Hub client keeps this repo's files under `baseURL`.
    private static let repoURL = baseURL.appending(path: "models/\(repo)", directoryHint: .isDirectory)
    private static let manifestURL = baseURL.appending(path: "installed.json")

    private init() {
        let device = WhisperKit.deviceName()
        let support = WhisperKit.recommendedModels()
        let known = Constants.fallbackModelSupportConfig.deviceSupports
            .contains { support in support.identifiers.contains { device.hasPrefix($0) } }
        supported = Set(support.supported)
        recommended = Self.tier(recommending: support.default, deviceIsKnown: known)
        refresh()
    }

    private static func tier(recommending variant: String, deviceIsKnown: Bool) -> ModelTier {
        #if arch(arm64)
        // Apple silicon newer than WhisperKit's table (M5 and later) gets its generic "base"
        // default; treat it like the newest chips the table does know.
        if !deviceIsKnown { return .accurate }
        #endif
        if variant.contains("large") || variant.contains("medium") { return .accurate }
        if variant.contains("small") { return .balanced }
        return .fast
    }

    func build(for tier: ModelTier) -> ModelBuild {
        tier.candidates.first { supported.contains($0.variant) } ?? tier.candidates[0]
    }

    func folder(for tier: ModelTier) -> URL {
        Self.repoURL.appending(path: build(for: tier).variant, directoryHint: .isDirectory)
    }

    func phase(_ tier: ModelTier) -> Phase { phases[tier] ?? .idle }

    func isInstalled(_ tier: ModelTier) -> Bool { installed.contains(tier) }

    var isDownloading: Bool {
        phases.values.contains { if case .downloading = $0 { true } else { false } }
    }

    /// Re-reads what's on disk; a model counts only if every file it was downloaded with is still there.
    func refresh() {
        let manifest = Self.readManifest()
        installed = Set(ModelTier.allCases.filter { tier in
            guard let files = manifest[build(for: tier).variant], !files.isEmpty else { return false }
            let folder = folder(for: tier)
            return files.allSatisfy { file in
                let size = (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: file.path).path)[.size]) as? Int64
                return size == file.size
            }
        })
    }

    // MARK: - Download

    func download(_ tier: ModelTier) {
        guard downloads[tier] == nil, !isInstalled(tier) else { return }
        phases[tier] = .downloading(0)
        downloads[tier] = Task { [weak self] in
            await self?.runDownload(tier)
        }
    }

    func cancelDownload(_ tier: ModelTier) {
        downloads[tier]?.cancel()
    }

    private func runDownload(_ tier: ModelTier) async {
        let build = build(for: tier)
        defer { downloads[tier] = nil }
        do {
            let files = try await Self.remoteFiles(for: build.variant)
            let total = max(1, files.reduce(0) { $0 + $1.size })

            let watcher = Task { [weak self] in
                while !Task.isCancelled {
                    let done = Self.bytesOnDisk(variant: build.variant)
                    self?.phases[tier] = .downloading(min(0.99, Double(done) / Double(total)))
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            defer { watcher.cancel() }

            try FileManager.default.createDirectory(at: Self.baseURL, withIntermediateDirectories: true)
            _ = try await WhisperKit.download(variant: build.variant, downloadBase: Self.baseURL, from: Self.repo)
            try Task.checkCancellation()
            // Fetch the tokenizer now so the model also loads offline later.
            _ = try await ModelUtilities.loadTokenizer(for: tier.tokenizer, tokenizerFolder: Self.baseURL)
            try Task.checkCancellation()

            let folder = folder(for: tier)
            let missing = files.filter { file in
                let size = (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: file.path).path)[.size]) as? Int64
                return size != file.size
            }
            guard missing.isEmpty else { throw DownloadError.incomplete }

            var manifest = Self.readManifest()
            manifest[build.variant] = files
            try Self.writeManifest(manifest)
            refresh()
            phases[tier] = .idle
        } catch {
            phases[tier] = Self.isCancellation(error) ? .idle : .failed(Self.message(for: error))
        }
    }

    // MARK: - Delete

    func delete(_ tier: ModelTier) async {
        if let download = downloads[tier] {
            download.cancel()
            // Let the download stop writing before its files go (but don't hang on one that won't stop).
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await download.value }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
        }
        let variant = build(for: tier).variant
        await WhisperService.shared.unload(ifVariant: variant)
        let fm = FileManager.default
        try? fm.removeItem(at: folder(for: tier))
        try? fm.removeItem(at: Self.repoURL.appending(path: ".cache/huggingface/download/\(variant)"))
        var manifest = Self.readManifest()
        manifest[variant] = nil
        if manifest.isEmpty {
            // Nothing left: take the shared tokenizers and caches too.
            try? fm.removeItem(at: Self.baseURL)
        } else {
            try? Self.writeManifest(manifest)
        }
        phases[tier] = .idle
        refresh()
    }

    // MARK: - Files

    nonisolated struct RemoteFile: Codable, Sendable {
        let path: String
        let size: Int64
    }

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64
    }

    /// The model's files and exact sizes from the Hub API; doubles as the "are we online" check.
    private static func remoteFiles(for variant: String) async throws -> [RemoteFile] {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repo)/tree/main/\(variant)")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.unavailable }
        let prefix = variant + "/"
        let files = try JSONDecoder().decode([TreeEntry].self, from: data)
            .filter { $0.type == "file" && $0.path.hasPrefix(prefix) }
            .map { RemoteFile(path: String($0.path.dropFirst(prefix.count)), size: $0.size) }
        guard !files.isEmpty else { throw DownloadError.unavailable }
        return files
    }

    /// Finished files plus partial ones, which the Hub client resumes from where they stopped.
    private static func bytesOnDisk(variant: String) -> Int64 {
        let folders = [repoURL.appending(path: variant), repoURL.appending(path: ".cache/huggingface/download/\(variant)")]
        var total: Int64 = 0
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in walker {
                let isPartial = url.pathExtension == "incomplete"
                guard isPartial || folder == folders[0] else { continue }
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    private static func readManifest() -> [String: [RemoteFile]] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [RemoteFile]].self, from: data)) ?? [:]
    }

    private static func writeManifest(_ manifest: [String: [RemoteFile]]) throws {
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }

    // MARK: - Errors

    private enum DownloadError: Error {
        case unavailable, incomplete
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func message(for error: Error) -> String {
        let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                           .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed]
        if let code = (error as? URLError)?.code, offline.contains(code) {
            return "You're offline. Connect to the internet to download the model."
        }
        switch error as? DownloadError {
        case .unavailable: return "Hugging Face didn't have this model. Try again later."
        case .incomplete: return "The download didn't finish. Try again to pick up where it stopped."
        case nil: break
        }
        if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileWriteOutOfSpaceError {
            return "There isn't enough disk space for this model."
        }
        return "The download stopped. Check your connection and try again."
    }
}
