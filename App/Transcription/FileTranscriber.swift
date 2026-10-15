import AVFoundation
import UniformTypeIdentifiers
import WhisperKit

/// Transcribes an audio or video file a couple of minutes at a time, so memory stays small however
/// long the file is and text appears as it goes. Each stretch is cut at quiet moments into pieces
/// Whisper reads in one pass, and the pieces run side by side.
nonisolated struct FileTranscriber {
    let service: WhisperService
    var options: DecodingOptions

    static let types: [UTType] = [
        .mpeg4Audio, .mp3, .wav, .aiff,
        UTType("com.apple.coreaudio-format"), UTType("org.xiph.flac"),
        .mpeg4Movie, .quickTimeMovie, UTType("com.apple.m4v-video"),
    ].compactMap { $0 }

    private static let rate = Double(AudioMixer.sampleRate)

    /// Reports the fraction done and each stretch's segments as they finish.
    @concurrent
    func run(url: URL, report: @escaping @MainActor @Sendable (Double, [TranscriptSegment]) -> Void) async throws {
        let rate = Self.rate
        let reader = try await AudioFileReader(url: url)
        defer { reader.cancel() }
        let totalSamples = max(1, reader.duration * rate)
        let stretch = Int(120 * rate)
        let longest = Int(28 * rate)
        var options = self.options
        var pending: [Float] = []
        var start = 0
        var atEnd = false

        while !(atEnd && pending.isEmpty) {
            try Task.checkCancellation()
            while !atEnd && pending.count < stretch + longest {
                if let samples = try reader.next() {
                    pending.append(contentsOf: samples)
                } else {
                    atEnd = true
                }
            }

            var pieces: [Range<Int>] = []
            var position = 0
            while position < pending.count, atEnd || position < stretch {
                if pending.count - position <= longest {
                    guard atEnd else { break }
                    pieces.append(position..<pending.count)
                    position = pending.count
                } else {
                    let cut = Self.quietPoint(in: pending, from: position + Int(18 * rate), to: position + longest)
                    pieces.append(position..<cut)
                    position = cut
                }
            }
            guard position > 0 else { break }

            // Near-silent pieces only make Whisper invent words.
            let audible = pieces.filter { !Self.isSilent(pending[$0]) }
            let results = audible.isEmpty
                ? []
                : try await service.transcribe(pieces: audible.map { Array(pending[$0]) }, options: options)
            var segments: [TranscriptSegment] = []
            for (piece, pieceResults) in zip(audible, results) {
                let offset = Double(start + piece.lowerBound) / rate
                for segment in pieceResults.flatMap(\.segments) {
                    guard let text = segment.spokenText else { continue }
                    segments.append(TranscriptSegment(start: offset + Double(segment.start),
                                                      end: offset + Double(segment.end), text: text))
                }
            }
            if options.language == nil, !segments.isEmpty,
               let language = results.joined().first(where: { !$0.segments.isEmpty })?.language {
                options.language = language
                options.detectLanguage = false
            }
            pending.removeFirst(position)
            start += position
            await report(min(1, Double(start) / totalSamples), segments)
        }
    }

    /// The middle of the longest silence between `lower` and `upper`, or `upper` if there's none.
    private static func quietPoint(in samples: [Float], from lower: Int, to upper: Int) -> Int {
        let vad = EnergyVAD()
        let activity = vad.voiceActivity(in: Array(samples[lower..<upper]))
        guard let silence = vad.findLongestSilence(in: activity) else { return upper }
        return lower + vad.voiceActivityIndexToAudioSampleIndex((silence.startIndex + silence.endIndex) / 2)
    }

    private static func isSilent(_ samples: ArraySlice<Float>) -> Bool {
        let frame = AudioMixer.sampleRate / 10
        return stride(from: samples.startIndex, to: samples.endIndex, by: frame).allSatisfy { index in
            let chunk = Array(samples[index..<min(index + frame, samples.endIndex)])
            return AudioProcessor.calculateAverageEnergy(of: chunk) < 0.003
        }
    }
}

/// Decodes the first audio track of any file AVFoundation can open as 16 kHz mono Float.
nonisolated final class AudioFileReader {
    let duration: TimeInterval
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var enabled: AVAssetTrack?
        for track in tracks {
            if try await track.load(.isEnabled) {
                enabled = track
                break
            }
        }
        guard let track = enabled ?? tracks.first else { throw FileTranscriptionError.noAudio }
        duration = try await asset.load(.duration).seconds
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioMixer.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FileTranscriptionError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FileTranscriptionError.unreadable }
    }

    /// The next few thousand samples, or nil at the end.
    func next() throws -> [Float]? {
        guard let buffer = output.copyNextSampleBuffer() else {
            if reader.status == .failed { throw reader.error ?? FileTranscriptionError.unreadable }
            return nil
        }
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? samples : []
    }

    func cancel() {
        if reader.status == .reading { reader.cancelReading() }
    }
}

nonisolated enum FileTranscriptionError: LocalizedError {
    case noAudio, unreadable

    var errorDescription: String? {
        switch self {
        case .noAudio: "This file has no sound to transcribe."
        case .unreadable: "Dead Center couldn't read the audio in this file."
        }
    }
}
