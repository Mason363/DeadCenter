import AppKit
import Observation
import UniformTypeIdentifiers

/// Runs transcription for the app: the transcript window, live sessions, files, and the
/// hand-off to the reader.
@Observable
final class TranscriptionController {
    static let shared = TranscriptionController()

    /// Audio and video the app can route here.
    static var supportedFileTypes: [UTType] { FileTranscriber.types }

    static func canTranscribe(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return supportedFileTypes.contains { type.conforms(to: $0) }
    }

    enum Activity: Equatable {
        case idle
        case starting
        case live
        case finishing
        case file(name: String, progress: Double)
    }

    enum ModelPhase: Equatable {
        case missing, unloaded, loading, ready
        case failed(String)
    }

    /// A one-line problem with an optional fix.
    struct Notice: Equatable {
        var text: String
        var action: String?
        var url: URL?
    }

    let transcript = Transcript()
    private(set) var activity: Activity = .idle
    private(set) var modelPhase: ModelPhase = .missing
    private(set) var notice: Notice?
    /// When the current live stretch began, and how much transcript time came before it.
    private(set) var liveSince: Date?
    private(set) var clockBase: TimeInterval = 0
    var followsInReader = false {
        didSet { followsInReader ? openFeedIfNeeded() : closeFeed() }
    }

    @ObservationIgnored private lazy var window = TranscriptWindowController(controller: self)
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var modelLoad: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var loadedTier: ModelTier?
    @ObservationIgnored private var captures: [AudioCapture] = []
    @ObservationIgnored private var mixer: AudioMixer?
    @ObservationIgnored private var systemLane: Int?
    @ObservationIgnored private var silenceWatch: Task<Void, Never>?
    @ObservationIgnored private var feed: LiveFeed?
    @ObservationIgnored private var feedBuffer: [String] = []
    @ObservationIgnored private var pendingFile: URL?
    @ObservationIgnored private var transcriptIsFromFile = false

    private let prefs = TranscriptionPreferences.shared
    private let store = ModelStore.shared

    var isBusy: Bool { activity != .idle }
    var isLive: Bool { activity == .live }

    // MARK: - Window

    func show() {
        window.show()
        prepareModel()
    }

    /// Transcribes an audio or video file into a fresh transcript in the window.
    func transcribe(file url: URL) {
        window.show()
        guard Self.canTranscribe(url) else {
            notice = Notice(text: "Dead Center can't transcribe .\(url.pathExtension) files.")
            return
        }
        pendingFile = url
        stopActivity()
        prepareModel()
        startPendingFileIfReady()
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedFileTypes
        panel.message = "Choose a recording or video to transcribe"
        panel.prompt = "Transcribe"
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.transcribe(file: url)
        }
    }

    /// The window closed: stop listening and give the model's memory back.
    func windowDidClose() {
        stopActivity()
        pendingFile = nil
        let finishing = job
        modelLoad?.cancel()
        modelLoad = nil
        loadGeneration += 1
        Task {
            await finishing?.value
            guard !window.isVisible else { return }
            await WhisperService.shared.unload()
            loadedTier = nil
            modelPhase = store.isInstalled(prefs.model) ? .unloaded : .missing
        }
    }

    // MARK: - Model

    /// Loads the chosen model in the background if it's downloaded and not already loaded.
    func prepareModel() {
        let tier = prefs.model
        guard store.isInstalled(tier) else {
            modelPhase = .missing
            return
        }
        guard loadedTier != tier || modelPhase != .ready, modelLoad == nil, window.isVisible else { return }
        // Switching models waits until the running session is done with the current one.
        if loadedTier != nil, activity != .idle, activity != .starting { return }
        modelPhase = .loading
        let build = store.build(for: tier)
        let folder = store.folder(for: tier)
        loadGeneration += 1
        let generation = loadGeneration
        modelLoad = Task {
            defer { if loadGeneration == generation { modelLoad = nil } }
            do {
                try await WhisperService.shared.load(variant: build.variant, folder: folder)
                guard !Task.isCancelled else { return }
                loadedTier = tier
                modelPhase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                loadedTier = nil
                modelPhase = .failed("The speech model couldn't be loaded. Delete it in Settings and download it again.")
                return
            }
            if tier != prefs.model {
                modelLoad = nil
                prepareModel()
            }
            startPendingFileIfReady()
        }
    }

    private func waitForModel() async throws {
        prepareModel()
        await modelLoad?.value
        try Task.checkCancellation()
        switch modelPhase {
        case .ready: return
        case .failed(let message): throw ModelError(message: message)
        case .missing: throw ModelError(message: "Download the speech model in Settings to transcribe.")
        case .unloaded, .loading: throw CancellationError()
        }
    }

    private struct ModelError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Live

    func toggleRecording() {
        switch activity {
        case .idle: startLive()
        case .live: stopLive()
        case .starting, .finishing, .file: break
        }
    }

    func startLive() {
        guard activity == .idle else { return }
        guard store.isInstalled(prefs.model) else {
            notice = Notice(text: "Download the speech model in Settings to transcribe.")
            return
        }
        notice = nil
        activity = .starting
        job = Task { await runLive() }
    }

    func stopLive() {
        guard activity == .live else { return }
        activity = .finishing
        stopCapture()
    }

    private func runLive() async {
        let source = prefs.source
        do {
            try await waitForModel()
            if source.usesMicrophone { try await requireMicrophone() }
            try Task.checkCancellation()
            try await startCapture(source)
            try Task.checkCancellation()
        } catch {
            stopCapture()
            activity = .idle
            if !(error is CancellationError) { notice = Self.notice(for: error) }
            return
        }

        if transcriptIsFromFile || transcript.isEmpty {
            transcript.reset(title: Self.liveTitle())
            transcriptIsFromFile = false
            clockBase = 0
        }
        clockBase = max(clockBase, transcript.duration)
        liveSince = Date()
        activity = .live
        openFeedIfNeeded()
        watchSystemAudio()

        let transcriber = LiveTranscriber(service: .shared, options: prefs.decodingOptions,
                                          startOffset: clockBase)
        do {
            guard let mixer else { return }
            try await transcriber.run(mixer: mixer) { [weak self] update in
                self?.apply(update)
            }
        } catch is CancellationError {
        } catch {
            notice = Self.notice(for: error)
        }
        stopCapture()
        transcript.setTentative("")
        clockBase += liveSince.map { Date().timeIntervalSince($0) } ?? 0
        liveSince = nil
        activity = .idle
        closeFeed()
        if notice?.url == AudioPermissions.systemAudioSettings { notice = nil }
        prepareModel()
        startPendingFileIfReady()
    }

    private func apply(_ update: LiveUpdate) {
        transcript.append(update.confirmed)
        transcript.setTentative(update.tentative)
        sendToFeed(update.confirmed)
    }

    private func requireMicrophone() async throws {
        switch AudioPermissions.microphone {
        case .authorized: return
        case .notDetermined:
            if await AudioPermissions.requestMicrophone() { return }
        default: break
        }
        throw CaptureError.microphoneDenied
    }

    private func startCapture(_ source: AudioSource) async throws {
        var captures: [AudioCapture] = []
        if source.usesMicrophone {
            captures.append(MicrophoneCapture(deviceUID: prefs.inputDeviceUID.isEmpty ? nil : prefs.inputDeviceUID))
        }
        if source.usesSystemAudio {
            systemLane = captures.count
            captures.append(SystemAudioCapture())
        } else {
            systemLane = nil
        }
        let mixer = AudioMixer(lanes: captures.count)
        self.mixer = mixer
        self.captures = captures
        for (lane, capture) in captures.enumerated() {
            try await capture.start(into: mixer, lane: lane)
        }
    }

    private func stopCapture() {
        silenceWatch?.cancel()
        silenceWatch = nil
        captures.forEach { $0.stop() }
        captures = []
        mixer?.finish()
        mixer = nil
    }

    /// A denied system-audio permission doesn't fail; the tap just hears silence. Say so if it lasts.
    private func watchSystemAudio() {
        guard let lane = systemLane, let mixer else { return }
        silenceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isLive else { return }
                let (delivered, silentTail) = mixer.silence(lane: lane)
                let hint = Notice(text: "Not hearing other apps. If something is playing, allow Dead Center to record system audio.",
                                  action: "Open Settings", url: AudioPermissions.systemAudioSettings)
                if delivered >= 8 && silentTail >= 8 {
                    if self.notice == nil { self.notice = hint }
                } else if self.notice == hint {
                    self.notice = nil
                }
            }
        }
    }

    // MARK: - Files

    private func startPendingFileIfReady() {
        guard let url = pendingFile, activity == .idle else { return }
        guard store.isInstalled(prefs.model) else { return }
        guard modelPhase == .ready else {
            prepareModel()
            return
        }
        pendingFile = nil
        notice = nil
        let name = url.deletingPathExtension().lastPathComponent
        transcript.reset(title: name)
        transcriptIsFromFile = true
        clockBase = 0
        activity = .file(name: name, progress: 0)
        openFeedIfNeeded()
        let transcriber = FileTranscriber(service: .shared, options: prefs.decodingOptions)
        job = Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try await transcriber.run(url: url) { progress, segments in
                    guard case .file = self.activity else { return }
                    self.transcript.append(segments)
                    self.sendToFeed(segments)
                    self.activity = .file(name: name, progress: progress)
                }
                clockBase = transcript.duration
                if transcript.isEmpty { notice = Notice(text: "No speech was found in “\(name)”.") }
            } catch is CancellationError {
            } catch {
                notice = Self.notice(for: error)
            }
            activity = .idle
            closeFeed()
            prepareModel()
            startPendingFileIfReady()
        }
    }

    /// Stops whatever is running; a live session still confirms what it has heard.
    private func stopActivity() {
        switch activity {
        case .live: stopLive()
        case .file, .starting: job?.cancel()
        case .idle, .finishing: break
        }
    }

    // MARK: - Actions

    func newTranscript() {
        guard !isBusy else { return }
        transcript.reset(title: Self.liveTitle())
        transcriptIsFromFile = false
        clockBase = 0
        notice = nil
    }

    var exportText: String {
        Transcript.join([transcript.plainText, transcript.tentative])
    }

    func copyAll() {
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportText, forType: .string)
    }

    func readInDeadCenter() {
        ReadingCoordinator.shared.read(text: exportText, origin: .text, title: transcript.title)
    }

    func save() {
        guard !transcript.isEmpty else { return }
        window.presentSavePanel(for: transcript)
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: - Reader feed

    private func openFeedIfNeeded() {
        guard followsInReader, feed == nil, isBusy else { return }
        feedBuffer = []
        feed = ReadingCoordinator.shared.startLive(title: transcript.title)
    }

    /// The reader treats each append as a paragraph, so whole sentences are sent rather than fragments.
    private func sendToFeed(_ segments: [TranscriptSegment]) {
        guard let feed else { return }
        if ReadingCoordinator.shared.session !== feed.session {
            // The reader moved on to something else.
            followsInReader = false
            return
        }
        for segment in segments {
            if segment.startsParagraph { flushFeed() }
            feedBuffer.append(segment.text)
            if let last = segment.text.last, ".?!。？！".contains(last) { flushFeed() }
        }
        if feedBuffer.count >= 6 { flushFeed() }
    }

    private func flushFeed() {
        guard !feedBuffer.isEmpty else { return }
        feed?.append(Transcript.join(feedBuffer))
        feedBuffer = []
    }

    private func closeFeed() {
        flushFeed()
        feed?.finish()
        feed = nil
    }

    // MARK: - Helpers

    private static func liveTitle() -> String {
        "Transcript, " + Date.now.formatted(date: .abbreviated, time: .shortened)
    }

    private static func notice(for error: Error) -> Notice {
        switch error as? CaptureError {
        case .microphoneDenied:
            return Notice(text: "Dead Center can't hear your microphone.", action: "Open Settings",
                          url: AudioPermissions.microphoneSettings)
        case .screenRecordingDenied:
            return Notice(text: "Dead Center needs permission to record system audio.", action: "Open Settings",
                          url: AudioPermissions.systemAudioSettings)
        default:
            return Notice(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
