import AVFoundation
import Accelerate

/// Where captured audio meets the transcriber: each source writes 16 kHz mono samples into its own
/// lane from its audio thread, and the transcriber drains one mixed stream.
nonisolated final class AudioMixer: @unchecked Sendable {
    static let sampleRate = 16_000

    private let lock = NSLock()
    private var lanes: [[Float]]
    private var lastSound: [Int]
    private var written: [Int]
    private var isFinished = false

    /// Lanes may drift apart (separate clocks, a source that stalls); past this the late one is padded with silence.
    private let maxLag = sampleRate / 2
    /// If the transcriber falls far behind, the oldest audio goes rather than memory.
    private let maxBuffered = sampleRate * 60

    init(lanes count: Int) {
        lanes = Array(repeating: [], count: count)
        lastSound = Array(repeating: 0, count: count)
        written = Array(repeating: 0, count: count)
    }

    var laneCount: Int { lanes.count }

    func write(_ samples: [Float], lane: Int) {
        guard !samples.isEmpty else { return }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        lock.withLock {
            guard !isFinished else { return }
            lanes[lane].append(contentsOf: samples)
            written[lane] += samples.count
            if peak > 0 { lastSound[lane] = written[lane] }
            if lanes[lane].count > maxBuffered {
                lanes[lane].removeFirst(lanes[lane].count - maxBuffered)
            }
        }
    }

    /// Seconds of audio a lane has delivered, and how much of that was digital silence at the end.
    func silence(lane: Int) -> (delivered: Double, silentTail: Double) {
        lock.withLock {
            let rate = Double(Self.sampleRate)
            return (Double(written[lane]) / rate, Double(written[lane] - lastSound[lane]) / rate)
        }
    }

    func finish() {
        lock.withLock { isFinished = true }
    }

    /// Everything ready to transcribe, mixed down. `finished` once the sources have stopped and nothing is left.
    func drain() -> (samples: [Float], finished: Bool) {
        lock.withLock {
            if lanes.count == 1 {
                let out = lanes[0]
                lanes[0].removeAll(keepingCapacity: true)
                return (out, isFinished)
            }
            let longest = lanes.map(\.count).max() ?? 0
            for i in lanes.indices {
                let behind = longest - lanes[i].count
                if isFinished || behind > maxLag {
                    let pad = isFinished ? behind : behind - maxLag / 2
                    lanes[i].append(contentsOf: repeatElement(0, count: pad))
                }
            }
            let count = lanes.map(\.count).min() ?? 0
            guard count > 0 else { return ([], isFinished) }
            var mixed = Array(lanes[0][..<count])
            for i in lanes.indices.dropFirst() {
                mixed = vDSP.add(mixed, lanes[i][..<count])
            }
            for i in lanes.indices {
                lanes[i].removeFirst(count)
            }
            return (vDSP.clip(mixed, to: -1...1), isFinished)
        }
    }
}

/// Converts whatever a device delivers into 16 kHz mono Float.
nonisolated final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let inputRate: Double
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioMixer.sampleRate),
                                       channels: 1, interleaved: false)!

    init(from input: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw CaptureError.unsupportedFormat
        }
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter
        inputRate = input.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / inputRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        let feed = Feed(buffer)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            guard let next = feed.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Hands the converter one buffer, once.
    private final class Feed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}

nonisolated enum CaptureError: LocalizedError {
    case unsupportedFormat
    case noInputDevice
    case microphoneDenied
    case screenRecordingDenied
    case systemAudioUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "This audio device uses a format Dead Center can't read."
        case .noInputDevice: "No microphone is connected."
        case .microphoneDenied: "Dead Center doesn't have access to your microphone."
        case .screenRecordingDenied: "Dead Center needs Screen & System Audio Recording access to hear other apps."
        case .systemAudioUnavailable(let detail): "System audio couldn't start. \(detail)"
        }
    }
}
