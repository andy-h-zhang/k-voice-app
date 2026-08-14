import Foundation

/// How much audio has actually been written, readable without waiting for the
/// writer.
///
/// ## Why this is its own type with its own lock
///
/// `MicSource` keeps all of its mutable state behind one lock, and the tap
/// callback holds that lock across the whole write path — downmix, then
/// `AVAudioConverter.convert`, then `AVAudioFile.write`. That is deliberate and
/// correct: `stop()` must not be able to close the file out from under an
/// in-flight buffer.
///
/// The problem was who *else* took that lock. The record screen polls
/// `recordedDuration` ten times a second **on the main actor**, and
/// `recordedDuration` read the frame counter behind the same lock — so every
/// poll could block the main thread behind an AAC encode plus a disk write. On
/// a slow or contended volume (a library inside an iCloud-synced `~/Documents`
/// is the common case) those writes are not microseconds, and the main thread
/// stalls with them. A stalled main thread stops servicing the window, and a
/// `NavigationSplitView` that cannot redraw comes back *blank* — which is
/// exactly the reported "after I began recording the items in the left panel
/// disappeared and I can't do anything after that". The sidebar was never
/// hidden; the window simply stopped being drawn.
///
/// Splitting the counters out fixes that by construction. This lock is only
/// ever held around two integer/double field accesses — no I/O, no encoding, no
/// Objective-C, nothing that can block — so a reader's worst case is the length
/// of an `os_unfair_lock` critical section measured in nanoseconds, no matter
/// what the writer is doing to the file.
///
/// The invariant worth keeping: **nothing in this type may ever call out to
/// code it does not control while holding the lock.**
final class RecordingCounters: @unchecked Sendable {

    private let lock = UnfairLock()
    private var frames: Int64 = 0
    private var sampleRate: Double = 0

    /// Frames written so far.
    var writtenFrames: Int64 {
        lock.withLock { frames }
    }

    /// The sample rate the frames were written at, or 0 before a run starts.
    var recordedSampleRate: Double {
        lock.withLock { sampleRate }
    }

    /// Seconds of audio actually on disk.
    ///
    /// Zero — rather than a division by zero — before a run has established a
    /// sample rate.
    var duration: TimeInterval {
        lock.withLock {
            guard sampleRate > 0 else { return 0 }
            return Double(frames) / sampleRate
        }
    }

    /// Begins a run: zero frames at `sampleRate`.
    func begin(sampleRate: Double) {
        lock.withLock {
            self.frames = 0
            self.sampleRate = sampleRate
        }
    }

    /// Adds the frames from one written buffer.
    ///
    /// Called from the CoreAudio tap thread, once per buffer (~12 Hz at the
    /// 4096-frame tap size), and deliberately *not* while `MicSource`'s engine
    /// lock is held.
    func add(frames count: Int64) {
        lock.withLock { frames += count }
    }

    /// Clears both fields — a run that failed to start wrote nothing, and
    /// `duration` should say so.
    func reset() {
        lock.withLock {
            frames = 0
            sampleRate = 0
        }
    }

    /// Both fields read together, so a summary cannot mix a frame count from
    /// one run with a sample rate from another.
    func snapshot() -> (frames: Int64, sampleRate: Double) {
        lock.withLock { (frames, sampleRate) }
    }
}
