import AVFoundation
import Foundation

/// Input-level math for the record-view meter.
///
/// Pure functions over samples — no engine, no hardware — so the meter's
/// behaviour is unit-testable. `MicSource` calls these from its tap callback
/// on the raw (pre-conversion) input buffer, so the meter reflects what the
/// microphone actually hears.
public enum AudioLevel {
    /// Level in dBFS mapped to `0` on the meter. Quiet room tone sits around
    /// -50 dBFS, speech peaks around -12; -60 keeps the bar responsive
    /// without pinning it to the floor.
    public static let defaultFloorDB: Float = -60

    /// Digital silence in dBFS. `log10(0)` is -infinity, so it is clamped.
    public static let silenceDB: Float = -160

    // MARK: - RMS

    /// Root mean square of `samples`, in the same units as the input
    /// (`0...1` for normalized float audio).
    ///
    /// Non-finite samples are skipped rather than poisoning the result with
    /// NaN — a single bad frame from a misbehaving driver should not blank
    /// the meter. Returns `0` for an empty buffer.
    public static func rms(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return rms(base, count: buffer.count)
        }
    }

    /// Root mean square over `count` samples starting at `samples`.
    public static func rms(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }

        var sumOfSquares = Double.zero
        var counted = 0
        for index in 0..<count {
            let value = samples[index]
            guard value.isFinite else { continue }
            sumOfSquares += Double(value) * Double(value)
            counted += 1
        }

        guard counted > 0 else { return 0 }
        return Float((sumOfSquares / Double(counted)).squareRoot())
    }

    // MARK: - Scaling

    /// Converts an RMS amplitude to dBFS, clamped at ``silenceDB``.
    public static func decibels(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return silenceDB }
        return max(silenceDB, 20 * log10(rms))
    }

    /// Maps dBFS onto `0...1`, where `floor` and quieter map to `0` and
    /// 0 dBFS maps to `1`.
    public static func normalized(decibels: Float, floor: Float = defaultFloorDB) -> Float {
        guard decibels.isFinite else { return 0 }
        guard floor < 0 else { return decibels >= 0 ? 1 : 0 }
        let clamped = min(max(decibels, floor), 0)
        return (clamped - floor) / -floor
    }

    /// Maps an RMS amplitude straight onto a `0...1` meter value.
    public static func normalized(rms value: Float, floor: Float = defaultFloorDB) -> Float {
        normalized(decibels: decibels(rms: value), floor: floor)
    }

    /// Meter value for a block of samples: RMS → dBFS → `0...1`.
    public static func meterLevel(of samples: [Float], floor: Float = defaultFloorDB) -> Float {
        normalized(rms: rms(samples), floor: floor)
    }

    // MARK: - Buffers

    /// Root mean square across every channel of a PCM buffer.
    ///
    /// Supports the float and 16-bit integer layouts an input tap can hand
    /// back, interleaved or not. Returns `0` for formats it cannot read,
    /// which shows as a dead meter rather than a crash.
    public static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        let isInterleaved = buffer.format.isInterleaved
        // Interleaved buffers expose one pointer holding every channel;
        // deinterleaved buffers expose one pointer per channel.
        let pointerCount = isInterleaved ? 1 : channelCount
        let samplesPerPointer = isInterleaved ? frameCount * channelCount : frameCount

        if let floatData = buffer.floatChannelData {
            var sumOfSquares = Double.zero
            var counted = 0
            for pointerIndex in 0..<pointerCount {
                let channel = floatData[pointerIndex]
                for index in 0..<samplesPerPointer {
                    let value = channel[index]
                    guard value.isFinite else { continue }
                    sumOfSquares += Double(value) * Double(value)
                    counted += 1
                }
            }
            guard counted > 0 else { return 0 }
            return Float((sumOfSquares / Double(counted)).squareRoot())
        }

        if let intData = buffer.int16ChannelData {
            let scale = Double(Int16.max)
            var sumOfSquares = Double.zero
            var counted = 0
            for pointerIndex in 0..<pointerCount {
                let channel = intData[pointerIndex]
                for index in 0..<samplesPerPointer {
                    let value = Double(channel[index]) / scale
                    sumOfSquares += value * value
                    counted += 1
                }
            }
            guard counted > 0 else { return 0 }
            return Float((sumOfSquares / Double(counted)).squareRoot())
        }

        return 0
    }

    /// Meter value for a PCM buffer: RMS → dBFS → `0...1`.
    public static func meterLevel(of buffer: AVAudioPCMBuffer, floor: Float = defaultFloorDB) -> Float {
        normalized(rms: rms(of: buffer), floor: floor)
    }
}

/// Asymmetric smoothing for a level meter: rises quickly so transients are
/// visible, falls slowly so the bar does not flicker between buffers.
public struct LevelSmoother: Sendable, Equatable {
    /// Weight applied to a new, louder value (`0...1`; higher is snappier).
    public var attack: Float
    /// Weight applied to a new, quieter value (`0...1`; lower decays slower).
    public var release: Float
    /// Current smoothed value in `0...1`.
    public private(set) var value: Float

    public init(attack: Float = 0.6, release: Float = 0.2, initialValue: Float = 0) {
        self.attack = min(max(attack, 0), 1)
        self.release = min(max(release, 0), 1)
        self.value = min(max(initialValue, 0), 1)
    }

    /// Folds a new meter reading in and returns the smoothed value.
    @discardableResult
    public mutating func update(_ next: Float) -> Float {
        let target = next.isFinite ? min(max(next, 0), 1) : 0
        let weight = target > value ? attack : release
        value = value + (target - value) * weight
        // Snap to the rail once the exponential tail is inaudible, so the
        // meter actually reaches zero after silence.
        if abs(value - target) < 0.001 { value = target }
        return value
    }

    /// Resets the meter to zero.
    public mutating func reset() { value = 0 }
}
