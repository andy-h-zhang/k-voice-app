import AVFoundation
import Foundation

/// The encoding target for a recording.
///
/// v1 records AAC in an MPEG-4 container (`.m4a`) at 48 kHz mono, per
/// `docs/spec.md` §Core pipeline 1. Mono because the pipeline downstream
/// (AssemblyAI diarization, 16 kHz speaker embeddings) is mono anyway, and a
/// 2-hour meeting at 96 kbps is ~86 MB rather than ~170 MB.
public struct RecordingFormat: Sendable, Equatable {
    /// Output sample rate in Hz.
    public var sampleRate: Double
    /// Output channel count.
    public var channelCount: UInt32
    /// Target AAC bit rate in bits per second.
    public var bitRate: Int

    public init(sampleRate: Double = 48_000, channelCount: UInt32 = 1, bitRate: Int = 96_000) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitRate = bitRate
    }

    /// The v1 default: AAC, 48 kHz, mono, 96 kbps.
    public static let aacMono48k = RecordingFormat()

    /// Path extension the container requires. `AVAudioFile` infers the file
    /// type from the URL's extension, so this is not cosmetic.
    public var fileExtension: String { "m4a" }

    /// `AVAudioFile` / `AVAudioRecorder`-style settings for this format.
    public var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate
        ]
    }

    /// Same as `settings` without the bit-rate hint.
    ///
    /// Some encoder/rate combinations reject an explicit bit rate;
    /// `makeAudioFile(at:)` retries with this and lets the codec pick.
    public var settingsWithoutBitRate: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount
        ]
    }

    /// The uncompressed format frames are handed to the file in. Writing
    /// buffers in this format is what triggers AAC encoding on the way to
    /// disk.
    public var processingFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        )
    }

    /// Creates an empty audio file at `url` ready for streaming writes.
    ///
    /// - Throws: ``RecordingError/fileExtensionMismatch(expected:actual:)`` if
    ///   `url` has the wrong extension, or
    ///   ``RecordingError/fileCreationFailed(path:reason:)``.
    public func makeAudioFile(at url: URL) throws -> AVAudioFile {
        let actualExtension = url.pathExtension.lowercased()
        guard actualExtension == fileExtension else {
            throw RecordingError.fileExtensionMismatch(
                expected: fileExtension,
                actual: actualExtension
            )
        }

        do {
            return try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            // Retry without the explicit bit rate before giving up: the
            // encoder may reject the hint even though the format is fine.
            do {
                return try AVAudioFile(forWriting: url, settings: settingsWithoutBitRate)
            } catch {
                throw RecordingError.fileCreationFailed(
                    path: url.path,
                    reason: error.localizedDescription
                )
            }
        }
    }
}
