import AVFoundation
import CoreAudio
import ScreenCaptureKit

/// Something that feeds one lane of an `AudioMixer` until stopped.
nonisolated protocol AudioCapture: AnyObject, Sendable {
    func start(into mixer: AudioMixer, lane: Int) async throws
    func stop()
}

// MARK: - Microphone

/// The chosen input device (or the system default) through AVAudioEngine.
nonisolated final class MicrophoneCapture: AudioCapture, @unchecked Sendable {
    private let deviceUID: String?
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private let lock = NSLock()

    init(deviceUID: String?) {
        self.deviceUID = deviceUID
    }

    func start(into mixer: AudioMixer, lane: Int) async throws {
        try lock.withLock { try startEngine(mixer: mixer, lane: lane, deviceUID: deviceUID) }
    }

    private func startEngine(mixer: AudioMixer, lane: Int, deviceUID: String?) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID, var device = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        let resampler = try Resampler(from: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            mixer.write(resampler.convert(buffer), lane: lane)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine

        // A device that disappears (AirPods put away) reconfigures the engine and stops it; carry on
        // with whatever input the system picks next.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            self?.restart(mixer: mixer, lane: lane)
        }
    }

    private func restart(mixer: AudioMixer, lane: Int) {
        lock.withLock {
            guard engine != nil else { return }
            tearDown()
            let stillThere = deviceUID.flatMap(AudioDevices.deviceID(forUID:)) != nil
            try? startEngine(mixer: mixer, lane: lane, deviceUID: stillThere ? deviceUID : nil)
        }
    }

    func stop() {
        lock.withLock { tearDown() }
    }

    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

// MARK: - System audio

/// Everything the Mac plays: a Core Audio process tap where available, otherwise (or if the tap
/// can't be created) ScreenCaptureKit.
nonisolated final class SystemAudioCapture: AudioCapture, @unchecked Sendable {
    private var active: AudioCapture?
    private(set) var usesScreenCapture = false

    func start(into mixer: AudioMixer, lane: Int) async throws {
        if #available(macOS 14.2, *) {
            let tap = ProcessTapCapture()
            if (try? await tap.start(into: mixer, lane: lane)) != nil {
                active = tap
                return
            }
        }
        let screen = ScreenAudioCapture()
        try await screen.start(into: mixer, lane: lane)
        active = screen
        usesScreenCapture = true
    }

    func stop() {
        active?.stop()
        active = nil
    }
}

// MARK: - Core Audio process tap (macOS 14.2+)

/// Taps everything the Mac plays, except Dead Center itself, via a private aggregate device.
@available(macOS 14.2, *)
nonisolated final class ProcessTapCapture: AudioCapture, @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.mason363.DeadCenter.system-audio", qos: .userInitiated)

    func start(into mixer: AudioMixer, lane: Int) async throws {
        do {
            try setUp(mixer: mixer, lane: lane)
        } catch {
            stop()
            throw error
        }
    }

    private func setUp(mixer: AudioMixer, lane: Int) throws {
        let ownProcess = AudioDevices.processObject(pid: getpid()).map { [$0] } ?? []
        let tap = CATapDescription(monoGlobalTapButExcludeProcesses: ownProcess)
        tap.uuid = UUID()
        tap.name = "Dead Center Transcription"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "tap")

        guard let outputUID = AudioDevices.defaultOutputUID() else {
            throw CaptureError.systemAudioUnavailable("No output device is available.")
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dead Center Transcription",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "aggregate device")

        var stream = AudioStreamBasicDescription()
        guard AudioDevices.get(tapID, kAudioTapPropertyFormat, into: &stream),
              let format = AVAudioFormat(streamDescription: &stream) else {
            throw CaptureError.unsupportedFormat
        }
        let resampler = try Resampler(from: format)
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            mixer.write(resampler.convert(buffer), lane: lane)
        }, "audio callback")
        try check(AudioDeviceStart(aggregateID, procID), "start")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw CaptureError.systemAudioUnavailable("Core Audio couldn't create the \(step) (\(status)).")
        }
    }
}

// MARK: - ScreenCaptureKit (macOS 14.0–14.1)

/// Audio-only screen capture, for systems without process taps. Needs Screen Recording access.
nonisolated final class ScreenAudioCapture: NSObject, AudioCapture, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var mixer: AudioMixer?
    private var lane = 0
    private let queue = DispatchQueue(label: "com.mason363.DeadCenter.screen-audio", qos: .userInitiated)

    func start(into mixer: AudioMixer, lane: Int) async throws {
        self.mixer = mixer
        self.lane = lane
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.screenRecordingDenied
        }
        guard let display = content.displays.first else {
            throw CaptureError.systemAudioUnavailable("No display is available to capture from.")
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = AudioMixer.sampleRate
        configuration.channelCount = 1
        // Video can't be turned off; keep it tiny and rare.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let mixer, sampleBuffer.isValid else { return }
        var samples: [Float] = []
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let first = list.first, let data = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
        mixer.write(samples, lane: lane)
    }
}

// MARK: - Permissions

nonisolated enum AudioPermissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    /// "Screen & System Audio Recording", which also lists apps allowed to record system audio only.
    static let systemAudioSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
