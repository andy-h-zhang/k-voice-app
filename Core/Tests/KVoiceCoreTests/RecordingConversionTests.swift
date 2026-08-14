import AVFoundation
import Foundation
import Testing
@testable import KVoiceCore

/// The tap → converter → file half of the recorder, driven with synthesized
/// buffers instead of a microphone.
///
/// This is everything `MicSource` does with a captured buffer once it has
/// one: resample the hardware format to 48 kHz mono, write it to an AAC
/// `.m4a`, and finalize a file that reads back at the right length. Only the
/// capture callback itself needs real hardware.
@Suite("Recording conversion and file writing")
struct RecordingConversionTests {
    // MARK: - Conversion

    @Test("a matching format passes through with its frame count intact")
    func passThroughPreservesFrameCount() throws {
        let format = try monoFormat(sampleRate: 48_000)
        let input = try toneBuffer(format: format, frames: 4096, amplitude: 0.5)
        let converter = try #require(MicSource.makeConverter(from: format, to: format))

        let output = try #require(try MicSource.convert(input, using: converter, to: format))

        #expect(output.frameLength == 4096)
        #expect(output.format.sampleRate == 48_000)
        #expect(output.format.channelCount == 1)
    }

    /// The common real case: 44.1 kHz hardware, 48 kHz file.
    @Test("upsampling 44.1 kHz to 48 kHz produces the expected frame count")
    func resamplesFrom44100To48000() throws {
        let inputFormat = try stereoFormat(sampleRate: 44_100)
        let outputFormat = try monoFormat(sampleRate: 48_000)
        let input = try toneBuffer(format: inputFormat, frames: 4410, amplitude: 0.5)
        let converter = try #require(MicSource.makeConverter(from: inputFormat, to: outputFormat))

        let output = try #require(try MicSource.convert(input, using: converter, to: outputFormat))

        // 4410 frames at 44.1 kHz is 100 ms, which is 4800 frames at 48 kHz.
        // The first buffer runs short by the resampler's internal latency.
        #expect(output.frameLength > 4000)
        #expect(output.frameLength <= 4800)
        #expect(output.format.sampleRate == 48_000)
        #expect(output.format.channelCount == 1)
    }

    @Test("downsampling 96 kHz to 48 kHz halves the frame count")
    func resamplesFrom96000To48000() throws {
        let inputFormat = try monoFormat(sampleRate: 96_000)
        let outputFormat = try monoFormat(sampleRate: 48_000)
        let input = try toneBuffer(format: inputFormat, frames: 9600, amplitude: 0.5)
        let converter = try #require(MicSource.makeConverter(from: inputFormat, to: outputFormat))

        let output = try #require(try MicSource.convert(input, using: converter, to: outputFormat))

        #expect(output.frameLength > 4000)
        #expect(output.frameLength <= 4800)
    }

    @Test("stereo input becomes a single channel")
    func stereoBecomesMono() throws {
        let inputFormat = try stereoFormat(sampleRate: 48_000)
        let outputFormat = try monoFormat(sampleRate: 48_000)
        let input = try toneBuffer(format: inputFormat, frames: 4096, amplitude: 0.5)
        let converter = try #require(MicSource.makeConverter(from: inputFormat, to: outputFormat))

        let output = try #require(try MicSource.convert(input, using: converter, to: outputFormat))

        #expect(output.format.channelCount == 1)
        #expect(output.frameLength == 4096)
    }

    /// Silence in, silence out — and, more usefully, signal in, signal out at
    /// roughly the same level. A conversion that dropped or muted channels
    /// would show up here as a collapsed RMS.
    @Test("signal level survives conversion")
    func conversionPreservesLevel() throws {
        let inputFormat = try stereoFormat(sampleRate: 44_100)
        let outputFormat = try monoFormat(sampleRate: 48_000)
        let input = try toneBuffer(format: inputFormat, frames: 44_100, amplitude: 0.5)
        let converter = try #require(MicSource.makeConverter(from: inputFormat, to: outputFormat))

        let output = try #require(try MicSource.convert(input, using: converter, to: outputFormat))

        // A 0.5-amplitude sine has an RMS of 0.5/sqrt(2) ≈ 0.354.
        let outputRMS = AudioLevel.rms(of: output)
        #expect(abs(outputRMS - 0.354) < 0.05)
    }

    @Test("converting silence yields silence, not noise")
    func silenceStaysSilent() throws {
        let inputFormat = try stereoFormat(sampleRate: 44_100)
        let outputFormat = try monoFormat(sampleRate: 48_000)
        let input = try toneBuffer(format: inputFormat, frames: 4410, amplitude: 0)
        let converter = try #require(MicSource.makeConverter(from: inputFormat, to: outputFormat))

        let output = try #require(try MicSource.convert(input, using: converter, to: outputFormat))

        #expect(AudioLevel.rms(of: output) < 0.0001)
    }

    @Test("an empty buffer converts to nothing rather than failing")
    func emptyBufferConvertsToNil() throws {
        let format = try monoFormat(sampleRate: 48_000)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        input.frameLength = 0
        let converter = try #require(MicSource.makeConverter(from: format, to: format))

        #expect(try MicSource.convert(input, using: converter, to: format) == nil)
    }

    @Test("16-bit integer input converts to the float file format")
    func int16InputConverts() throws {
        let inputFormat = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)
        )
        let outputFormat = try monoFormat(sampleRate: 48_000)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1024))
        input.frameLength = 1024
        let samples = try #require(input.int16ChannelData)[0]
        for index in 0..<1024 {
            samples[index] = Int16(Double(Int16.max) * 0.5 * sin(2 * .pi * 440 * Double(index) / 48_000))
        }

        let converter = try #require(MicSource.makeConverter(from: inputFormat, to: outputFormat))
        let output = try #require(try MicSource.convert(input, using: converter, to: outputFormat))

        #expect(output.format.commonFormat == .pcmFormatFloat32)
        #expect(output.frameLength == 1024)
        #expect(AudioLevel.rms(of: output) > 0.1)
    }

    // MARK: - Streaming to an .m4a

    /// The whole write path: convert buffer after buffer into an open
    /// `AVAudioFile`, close it, and read the result back. Proves the file is
    /// finalized and the duration matches what was written — the two things
    /// that make a recording usable.
    @Test("streamed buffers produce a playable .m4a of the right duration")
    func streamsToPlayableM4A() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("streamed.m4a")
            let inputFormat = try stereoFormat(sampleRate: 44_100)

            var writtenFrames: Int64 = 0
            // Scoped so the file is released — and therefore finalized —
            // before it is read back.
            do {
                let file = try RecordingFormat.aacMono48k.makeAudioFile(at: url)
                let converter = try #require(
                    MicSource.makeConverter(from: inputFormat, to: file.processingFormat)
                )

                // 25 tap-sized buffers ≈ 2.3 seconds of audio.
                for _ in 0..<25 {
                    let input = try toneBuffer(format: inputFormat, frames: 4096, amplitude: 0.4)
                    guard let converted = try MicSource.convert(
                        input,
                        using: converter,
                        to: file.processingFormat
                    ) else { continue }
                    try file.write(from: converted)
                    writtenFrames += Int64(converted.frameLength)
                }
            }

            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(writtenFrames > 0)

            let expected = Double(writtenFrames) / 48_000
            let probed = try RecordingStore.duration(ofAudioAt: url)
            // AAC adds encoder priming frames, so the file reads back a hair
            // longer than the samples handed to it.
            #expect(probed >= expected - 0.05)
            #expect(probed - expected < 0.2)

            let readBack = try AVAudioFile(forReading: url)
            #expect(readBack.fileFormat.sampleRate == 48_000)
            #expect(readBack.fileFormat.channelCount == 1)
            #expect(readBack.length > 0)
        }
    }

    @Test("the encoded file is far smaller than the raw samples")
    func encodedFileIsCompressed() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("compressed.m4a")
            let format = try monoFormat(sampleRate: 48_000)

            do {
                let file = try RecordingFormat.aacMono48k.makeAudioFile(at: url)
                for _ in 0..<50 {
                    try file.write(from: try toneBuffer(format: format, frames: 4800, amplitude: 0.4))
                }
            }

            let size = try #require(
                try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
            )
            // 5 seconds of 48 kHz mono float is ~960 KB uncompressed; AAC at
            // 96 kbps should be nearer 60 KB.
            #expect(size > 0)
            #expect(size < 400_000)
        }
    }
}

// MARK: - Helpers

private func monoFormat(sampleRate: Double) throws -> AVAudioFormat {
    try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    )
}

private func stereoFormat(sampleRate: Double) throws -> AVAudioFormat {
    try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)
    )
}

/// A buffer of a 440 Hz sine at `amplitude`, identical on every channel.
///
/// Identical channels keep the test honest whichever way the converter
/// handles a stereo-to-mono downmix (averaging or selecting a channel).
private func toneBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, amplitude: Float) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames

    let channels = try #require(buffer.floatChannelData)
    for channel in 0..<Int(format.channelCount) {
        for frame in 0..<Int(frames) {
            channels[channel][frame] = amplitude * sin(2 * .pi * 440 * Float(frame) / Float(format.sampleRate))
        }
    }
    return buffer
}

private func withTemporaryDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kvoice-conversion-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}
