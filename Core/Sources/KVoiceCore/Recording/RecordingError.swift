import Foundation

/// Typed failures from the recording engine.
///
/// Every case carries a user-presentable `errorDescription`; the app layer
/// and `speakerlab record` both surface these directly rather than dumping
/// an `NSError`.
public enum RecordingError: Error, Equatable, Sendable {
    /// Microphone access was denied.
    case microphonePermissionDenied
    /// The system never answered the microphone-access request.
    ///
    /// Observed with binaries TCC has no identity for — a bare CLI tool run
    /// outside a terminal that already holds a microphone grant. The request
    /// callback simply never fires, so it is bounded by a timeout rather
    /// than left to hang forever.
    case microphonePermissionRequestTimedOut
    /// No usable input device: none connected, or the engine reports a
    /// zero-rate/zero-channel input format.
    case noInputDevice
    /// `--device <uid>` did not match any connected input device.
    case inputDeviceNotFound(uid: String)
    /// The input device list could not be read from CoreAudio.
    case deviceEnumerationFailed(status: Int32)
    /// The engine's input unit rejected the requested device.
    case deviceSelectionFailed(uid: String, status: Int32)
    /// The input device disappeared (or reconfigured) mid-recording.
    /// Capture is paused; audio written so far is intact.
    case inputDeviceDisconnected
    /// The system interrupted capture (iOS).
    case interrupted
    /// The destination file could not be created.
    case fileCreationFailed(path: String, reason: String)
    /// No converter exists between the input format and the file format.
    case converterUnavailable(from: String, to: String)
    /// Format conversion failed mid-stream.
    case conversionFailed(String)
    /// Writing converted frames to disk failed (disk full, volume ejected).
    case writeFailed(String)
    /// `AVAudioEngine.start()` failed.
    case engineStartFailed(String)
    /// `start()` called on a source that is already recording.
    case alreadyRecording
    /// `resume()` called on a source that is not paused.
    case notPaused
    /// `start()` called on a source that has already been stopped — sources
    /// are single-use.
    case sourceAlreadyStopped
    /// The destination URL's path extension does not match the format.
    case fileExtensionMismatch(expected: String, actual: String)
}

extension RecordingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return """
            Microphone access denied. Grant access in System Settings > Privacy \
            & Security > Microphone (for a command-line tool, grant it to the \
            terminal app running it).
            """
        case .microphonePermissionRequestTimedOut:
            return """
            The system did not respond to the microphone-access request. This \
            happens when the process has no identity the permission system can \
            prompt for — grant Microphone access to the terminal application \
            running this tool in System Settings > Privacy & Security > \
            Microphone, then try again.
            """
        case .noInputDevice:
            return "No usable audio input device is available."
        case .inputDeviceNotFound(let uid):
            return "No input device with UID '\(uid)'. Run with --list-devices to see the available ones."
        case .deviceEnumerationFailed(let status):
            return "Could not read the audio input device list (CoreAudio status \(status))."
        case .deviceSelectionFailed(let uid, let status):
            return "Could not select input device '\(uid)' (CoreAudio status \(status))."
        case .inputDeviceDisconnected:
            return """
            The audio input device disconnected or changed configuration. \
            Recording is paused and the file is intact up to the last frame; \
            resume to continue on the current input device.
            """
        case .interrupted:
            return "Recording was interrupted by the system and is paused."
        case .fileCreationFailed(let path, let reason):
            return "Could not create the recording file at \(path): \(reason)"
        case .converterUnavailable(let from, let to):
            return "No audio converter is available from \(from) to \(to)."
        case .conversionFailed(let reason):
            return "Audio conversion failed: \(reason)"
        case .writeFailed(let reason):
            return "Writing audio to disk failed: \(reason)"
        case .engineStartFailed(let reason):
            return "The audio engine failed to start: \(reason)"
        case .alreadyRecording:
            return "This audio source is already recording."
        case .notPaused:
            return "This audio source is not paused."
        case .sourceAlreadyStopped:
            return "This audio source has already been stopped; create a new one to record again."
        case .fileExtensionMismatch(let expected, let actual):
            return "The recording file must have the '.\(expected)' extension, not '.\(actual)'."
        }
    }
}
