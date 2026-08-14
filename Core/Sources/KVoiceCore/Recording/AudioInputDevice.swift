#if os(macOS)
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// A connected audio input device.
///
/// Identified by UID rather than `AudioDeviceID`: device IDs are reassigned
/// across reboots and reconnects, while the UID is stable enough to persist
/// in settings (`docs/implementation-plan.md` §1, "input device UID").
///
/// macOS only — CoreAudio's device APIs do not exist on iOS, where input
/// selection goes through `AVAudioSession` instead.
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    /// Stable identifier suitable for persisting in settings.
    public var id: String { uid }
    /// CoreAudio device UID.
    public let uid: String
    /// Human-readable name, e.g. "MacBook Pro Microphone".
    public let name: String
    /// CoreAudio device ID. Valid for this process run only.
    public let deviceID: AudioDeviceID
    /// Total input channels across the device's input streams.
    public let inputChannelCount: Int
    /// The device's current nominal sample rate in Hz (0 if unavailable).
    public let nominalSampleRate: Double
    /// Whether this is the system's current default input device.
    public let isDefault: Bool

    public init(
        uid: String,
        name: String,
        deviceID: AudioDeviceID,
        inputChannelCount: Int,
        nominalSampleRate: Double,
        isDefault: Bool
    ) {
        self.uid = uid
        self.name = name
        self.deviceID = deviceID
        self.inputChannelCount = inputChannelCount
        self.nominalSampleRate = nominalSampleRate
        self.isDefault = isDefault
    }
}

/// Enumerates CoreAudio input devices and points an `AVAudioEngine` at one.
///
/// Reading the device list needs no microphone permission — only capturing
/// does — so `speakerlab record --list-devices` works even where TCC has not
/// granted access.
public enum AudioDeviceManager {
    // MARK: - Enumeration

    /// Every connected device that has at least one input channel, default
    /// device first, then alphabetical.
    public static func inputDevices() throws -> [AudioInputDevice] {
        let defaultID = try? defaultInputDeviceID()

        let devices: [AudioInputDevice] = try allDeviceIDs().compactMap { deviceID in
            let channels = inputChannelCount(of: deviceID)
            guard channels > 0 else { return nil }
            guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID) else { return nil }
            let name = stringProperty(kAudioObjectPropertyName, of: deviceID) ?? uid
            return AudioInputDevice(
                uid: uid,
                name: name,
                deviceID: deviceID,
                inputChannelCount: channels,
                nominalSampleRate: nominalSampleRate(of: deviceID),
                isDefault: deviceID == defaultID
            )
        }

        return devices.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The system default input device, if there is one.
    public static func defaultInputDevice() throws -> AudioInputDevice? {
        guard let defaultID = try defaultInputDeviceID() else { return nil }
        return try inputDevices().first { $0.deviceID == defaultID }
    }

    /// Looks up an input device by UID.
    ///
    /// - Throws: ``RecordingError/inputDeviceNotFound(uid:)``.
    public static func inputDevice(withUID uid: String) throws -> AudioInputDevice {
        guard let device = try inputDevices().first(where: { $0.uid == uid }) else {
            throw RecordingError.inputDeviceNotFound(uid: uid)
        }
        return device
    }

    // MARK: - Selection

    /// Points the engine's input node at a specific device.
    ///
    /// Must be called while the engine is stopped and before the input
    /// format is read — the format follows the device, not the other way
    /// round.
    ///
    /// - Throws: ``RecordingError/inputDeviceNotFound(uid:)`` or
    ///   ``RecordingError/deviceSelectionFailed(uid:status:)``.
    public static func setInputDevice(uid: String, on engine: AVAudioEngine) throws {
        let device = try inputDevice(withUID: uid)
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw RecordingError.deviceSelectionFailed(uid: uid, status: kAudioUnitErr_Uninitialized)
        }

        var deviceID = device.deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw RecordingError.deviceSelectionFailed(uid: uid, status: status)
        }
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr else {
            throw RecordingError.deviceEnumerationFailed(status: status)
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else {
            throw RecordingError.deviceEnumerationFailed(status: status)
        }
        return deviceIDs
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr else {
            throw RecordingError.deviceEnumerationFailed(status: status)
        }
        return deviceID == AudioDeviceID(kAudioObjectUnknown) ? nil : deviceID
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }

        guard status == noErr, let value else { return nil }
        // CoreAudio hands back a +1 reference; take it rather than leak it.
        return value.takeRetainedValue() as String
    }

    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return 0 }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, storage) == noErr
        else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate) == noErr
        else { return 0 }
        return sampleRate
    }
}
#endif
