import AVFoundation
import Foundation

/// Reads arbitrary time spans out of a recording as 16 kHz mono Float32.
///
/// Spec §3 step 2 / plan §2 Phase 1 item 4. Works on the compressed `.m4a`
/// directly — `AVAudioFile` decodes AAC on the fly, so there is no
/// intermediate WAV on disk.
///
/// Two implementation choices worth knowing:
///
/// - **Downmix first, resample second.** Multi-channel → mono is done by
///   averaging channels ourselves, then a mono → mono sample-rate conversion
///   runs through `AVAudioConverter`. Handing a channel-count *and* rate
///   change to the converter in one step depends on channel-layout mapping
///   that varies by input file; splitting the two removes that variable.
/// - **Streaming.** Reads and converts in chunks with a single converter
///   instance (which carries the resampler's filter state across chunks), so
///   memory is bounded by the chunk size, not the file length. A 2-hour
///   recording is safe to read end-to-end.
///
/// AVFoundation only — no AppKit/UIKit, so the iOS path stays open (plan §1).
public struct AudioSpanExtractor: Sendable {

    /// What every speaker-embedding model in play expects.
    public static let defaultSampleRate: Double = 16_000

    /// Frames read per iteration at the source rate.
    private static let readChunkFrames = 16_384

    public let targetSampleRate: Double

    public init(targetSampleRate: Double = AudioSpanExtractor.defaultSampleRate) {
        self.targetSampleRate = targetSampleRate
    }

    // MARK: - Public API

    /// Duration of the file in seconds.
    public func duration(of url: URL) throws -> Double {
        let file = try open(url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { throw AudioSpanExtractionError.unsupportedFormat(url: url) }
        return Double(file.length) / rate
    }

    /// Samples for one selected span.
    public func samples(from url: URL, span: AudioSpan) throws -> [Float] {
        try samples(from: url, startSeconds: span.startSeconds, endSeconds: span.endSeconds)
    }

    /// Samples for an arbitrary `[start, end)` range, clamped to the file.
    public func samples(from url: URL, startSeconds: Double, endSeconds: Double) throws -> [Float] {
        let file = try open(url)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0 else { throw AudioSpanExtractionError.unsupportedFormat(url: url) }

        let startFrame = max(0, Int64((startSeconds * rate).rounded()))
        let endFrame = min(file.length, Int64((endSeconds * rate).rounded()))
        guard endFrame > startFrame else {
            throw AudioSpanExtractionError.emptySpan(
                url: url,
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                fileDurationSeconds: Double(file.length) / rate
            )
        }

        file.framePosition = startFrame
        return try read(file: file, frames: Int(endFrame - startFrame), url: url)
    }

    /// The whole file as 16 kHz mono samples.
    public func samples(from url: URL) throws -> [Float] {
        let file = try open(url)
        return try read(file: file, frames: Int(file.length), url: url)
    }

    /// Splits a clip into fixed windows — the enrollment path.
    ///
    /// Spec §Voice profiles / plan §2 Phase 6: a ~30 s read becomes several
    /// embeddings rather than one averaged vector, so a profile captures
    /// within-session variation instead of smoothing it away.
    ///
    /// - Parameters:
    ///   - windowSeconds: Window length. ~5 s is the enrollment default.
    ///   - hopSeconds: Step between window starts; defaults to `windowSeconds`
    ///     (non-overlapping).
    ///   - minWindowSeconds: A trailing partial window shorter than this is
    ///     dropped rather than embedded.
    public func windows(
        from url: URL,
        windowSeconds: Double = 5,
        hopSeconds: Double? = nil,
        minWindowSeconds: Double = 2
    ) throws -> [[Float]] {
        guard windowSeconds > 0 else { return [] }
        let all = try samples(from: url)
        return Self.windows(
            of: all,
            sampleRate: targetSampleRate,
            windowSeconds: windowSeconds,
            hopSeconds: hopSeconds,
            minWindowSeconds: minWindowSeconds
        )
    }

    /// Pure windowing over an in-memory sample buffer — separated so it is
    /// testable without touching the filesystem.
    public static func windows(
        of samples: [Float],
        sampleRate: Double,
        windowSeconds: Double = 5,
        hopSeconds: Double? = nil,
        minWindowSeconds: Double = 2
    ) -> [[Float]] {
        guard windowSeconds > 0, sampleRate > 0, !samples.isEmpty else { return [] }

        let window = max(1, Int(windowSeconds * sampleRate))
        let hop = max(1, Int((hopSeconds ?? windowSeconds) * sampleRate))
        let minimum = max(1, Int(minWindowSeconds * sampleRate))

        var result: [[Float]] = []
        var start = 0
        while start < samples.count {
            let end = min(start + window, samples.count)
            let length = end - start
            if length >= min(window, minimum) {
                result.append(Array(samples[start..<end]))
            }
            if end == samples.count { break }
            start += hop
        }
        return result
    }

    // MARK: - Reading

    private func open(_ url: URL) throws -> AVAudioFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioSpanExtractionError.fileNotFound(url: url)
        }
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw AudioSpanExtractionError.unreadable(url: url, underlying: String(describing: error))
        }
    }

    /// Reads `frames` frames from the file's current position, downmixing to
    /// mono and resampling to `targetSampleRate` as it goes.
    private func read(file: AVAudioFile, frames: Int, url: URL) throws -> [Float] {
        let format = file.processingFormat
        let sourceRate = format.sampleRate
        guard frames > 0 else { return [] }

        let resampler = sourceRate == targetSampleRate
            ? nil
            : try MonoResampler(from: sourceRate, to: targetSampleRate, url: url)

        var output: [Float] = []
        output.reserveCapacity(Int(Double(frames) * targetSampleRate / max(sourceRate, 1)) + 1024)

        var remaining = frames
        while remaining > 0 {
            let request = AVAudioFrameCount(min(Self.readChunkFrames, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: request) else {
                throw AudioSpanExtractionError.unsupportedFormat(url: url)
            }

            do {
                try file.read(into: buffer, frameCount: request)
            } catch {
                throw AudioSpanExtractionError.unreadable(url: url, underlying: String(describing: error))
            }

            let produced = Int(buffer.frameLength)
            guard produced > 0 else { break }  // early EOF
            remaining -= produced

            let mono = Self.downmix(buffer)
            if let resampler {
                output.append(contentsOf: try resampler.append(mono))
            } else {
                output.append(contentsOf: mono)
            }
        }

        if let resampler {
            output.append(contentsOf: try resampler.finish())
        }
        return output
    }

    /// Averages all channels into one. `AVAudioFile.processingFormat` is
    /// always non-interleaved Float32, so `floatChannelData` is the right view.
    static func downmix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return [] }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 1 else {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }

        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let pointer = channels[channel]
            for frame in 0..<frames {
                mono[frame] += pointer[frame]
            }
        }
        let scale = 1 / Float(channelCount)
        for frame in 0..<frames {
            mono[frame] *= scale
        }
        return mono
    }
}

/// Mono → mono sample-rate conversion that keeps converter state across
/// chunks. One instance per read; feeding it chunk by chunk yields the same
/// result as converting the whole buffer at once, without the memory cost.
private final class MonoResampler {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let url: URL

    init(from inputRate: Double, to outputRate: Double, url: URL) throws {
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw AudioSpanExtractionError.resamplingFailed(
                url: url,
                underlying: "could not create a \(inputRate) Hz → \(outputRate) Hz converter"
            )
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.url = url
    }

    /// Converts one chunk. Signals `.noDataNow` (not `.endOfStream`) when the
    /// chunk is consumed, which leaves the converter primed for the next one.
    func append(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }

        guard
            let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw AudioSpanExtractionError.resamplingFailed(url: url, underlying: "could not allocate an input buffer")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        var supplied = false
        return try convert { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
    }

    /// Flushes the converter's tail.
    func finish() throws -> [Float] {
        try convert { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func convert(input block: @escaping AVAudioConverterInputBlock) throws -> [Float] {
        var collected: [Float] = []
        let capacity: AVAudioFrameCount = 8192

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw AudioSpanExtractionError.resamplingFailed(url: url, underlying: "could not allocate an output buffer")
            }

            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: block)

            if let channel = output.floatChannelData, output.frameLength > 0 {
                collected.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            }

            switch status {
            case .haveData:
                // Output buffer filled before the input was exhausted; go again.
                guard output.frameLength == capacity else { return collected }
            case .inputRanDry, .endOfStream:
                return collected
            case .error:
                throw AudioSpanExtractionError.resamplingFailed(
                    url: url,
                    underlying: error.map(String.init(describing:)) ?? "unknown converter error"
                )
            @unknown default:
                return collected
            }
        }
    }
}

public enum AudioSpanExtractionError: Error, Sendable, Equatable {
    case fileNotFound(url: URL)
    case unreadable(url: URL, underlying: String)
    case unsupportedFormat(url: URL)
    case emptySpan(url: URL, startSeconds: Double, endSeconds: Double, fileDurationSeconds: Double)
    case resamplingFailed(url: URL, underlying: String)
}

extension AudioSpanExtractionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "No audio file at \(url.path)"
        case .unreadable(let url, let underlying):
            return "Could not read \(url.lastPathComponent): \(underlying)"
        case .unsupportedFormat(let url):
            return "Unsupported audio format in \(url.lastPathComponent)"
        case .emptySpan(let url, let start, let end, let duration):
            return String(
                format: "Span %.2fs–%.2fs is empty or outside %@ (duration %.2fs)",
                start, end, url.lastPathComponent, duration
            )
        case .resamplingFailed(let url, let underlying):
            return "Could not resample \(url.lastPathComponent): \(underlying)"
        }
    }
}
