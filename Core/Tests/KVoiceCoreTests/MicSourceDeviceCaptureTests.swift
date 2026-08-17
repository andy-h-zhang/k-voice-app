#if os(macOS)
import AVFoundation
import Foundation
import Testing

@testable import KVoiceCore

/// The one thing about `MicSource` that cannot be tested without hardware, and
/// the one thing that broke: that frames actually arrive from the device the
/// caller asked for.
///
/// ## Why this is opt-in
///
/// It opens the microphone. That needs a connected input device and a TCC grant
/// the CI machine does not have, and a run without either would fail for reasons
/// that have nothing to do with the code. So it is off unless
/// `KVOICE_AUDIO_TESTS=1` is set:
///
/// ```
/// KVOICE_AUDIO_TESTS=1 swift test --filter MicSourceDeviceCapture
/// ```
///
/// ## What it is guarding
///
/// Selecting an input device by UID — which the app does the moment a user
/// touches the input picker — used to produce a recording of **zero frames**.
/// `AVAudioEngine` caches the input node's `outputFormat` before the device is
/// selected and never refreshes it, so the tap went in at the wrong sample rate
/// and no buffer ever arrived. It failed only where the chosen device's rate
/// differed from the cached one, which is why it looked like a property of the
/// machine rather than of the code.
///
/// Every connected device is exercised rather than just the default, because the
/// default was the one configuration that always worked: the bug lived entirely
/// in the explicitly-selected path.
@Suite(
    "MicSource device capture (hardware)",
    .enabled(if: ProcessInfo.processInfo.environment["KVOICE_AUDIO_TESTS"] == "1")
)
struct MicSourceDeviceCaptureTests {

    /// Long enough for many tap buffers (~85 ms each) and short enough to keep
    /// the suite quick.
    private static let captureSeconds: TimeInterval = 2.0

    @Test("every connected input device, selected by UID, delivers frames")
    func everyDeviceCaptures() async throws {
        let devices = try AudioDeviceManager.inputDevices()
        try #require(!devices.isEmpty, "no input devices connected")

        for device in devices {
            let summary = try await record(deviceUID: device.uid)
            #expect(
                summary != nil,
                "\(device.name) (\(device.nominalSampleRate) Hz) produced no summary"
            )
            #expect(
                (summary?.frameCount ?? 0) > 0,
                "\(device.name) (\(device.nominalSampleRate) Hz) captured zero frames"
            )
        }
    }

    @Test("the system default, selected implicitly, delivers frames")
    func defaultDeviceCaptures() async throws {
        let summary = try await record(deviceUID: nil)
        #expect((summary?.frameCount ?? 0) > 0, "the default device captured zero frames")
    }

    @Test("frames stop while paused and start again on resume")
    func pauseAndResume() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let source = MicSource(inputDeviceUID: nil, permissionRequestTimeout: 5)
        try await source.start(writingTo: url)

        try await Task.sleep(nanoseconds: 800_000_000)
        let whileRecording = source.recordedDuration
        #expect(whileRecording > 0, "nothing was captured before the pause")

        await source.pause()
        let atPause = source.recordedDuration
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(source.recordedDuration == atPause, "frames were written while paused")

        try await source.resume()
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(source.recordedDuration > atPause, "nothing was captured after the resume")

        let summary = await source.stop()
        #expect((summary?.frameCount ?? 0) > 0)
    }

    // MARK: - Helpers

    private func record(deviceUID: String?) async throws -> RecordingSummary? {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let source = MicSource(inputDeviceUID: deviceUID, permissionRequestTimeout: 5)
        try await source.start(writingTo: url)
        try await Task.sleep(nanoseconds: UInt64(Self.captureSeconds * 1_000_000_000))
        return await source.stop()
    }

    private static func temporaryURL() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-capture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("capture.m4a")
    }
}
#endif
