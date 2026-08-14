import Foundation
import Testing

@testable import KVoiceCore

@Suite("Recording counters: duration readable without waiting for the writer")
struct RecordingCountersTests {

    // MARK: - Arithmetic

    @Test("duration is zero before a run establishes a sample rate")
    func zeroBeforeBegin() {
        let counters = RecordingCounters()
        #expect(counters.duration == 0)
        #expect(counters.writtenFrames == 0)
        #expect(counters.recordedSampleRate == 0)
    }

    @Test("frames added at a known rate convert to seconds")
    func durationFromFrames() {
        let counters = RecordingCounters()
        counters.begin(sampleRate: 48_000)
        counters.add(frames: 48_000)
        #expect(counters.duration == 1.0)

        counters.add(frames: 24_000)
        #expect(counters.duration == 1.5)
        #expect(counters.writtenFrames == 72_000)
    }

    @Test("a run that adds no frames has zero duration, not a divide by zero")
    func beginWithoutFrames() {
        let counters = RecordingCounters()
        counters.begin(sampleRate: 44_100)
        #expect(counters.duration == 0)
        #expect(counters.recordedSampleRate == 44_100)
    }

    @Test("begin clears the previous run's frames")
    func beginResetsFrames() {
        let counters = RecordingCounters()
        counters.begin(sampleRate: 48_000)
        counters.add(frames: 96_000)
        #expect(counters.duration == 2.0)

        counters.begin(sampleRate: 48_000)
        #expect(counters.writtenFrames == 0)
        #expect(counters.duration == 0)
    }

    @Test("reset clears both fields, so a failed start reports nothing recorded")
    func resetClearsBoth() {
        let counters = RecordingCounters()
        counters.begin(sampleRate: 48_000)
        counters.add(frames: 4_800)
        counters.reset()

        #expect(counters.writtenFrames == 0)
        #expect(counters.recordedSampleRate == 0)
        #expect(counters.duration == 0)
    }

    @Test("snapshot reads both fields together")
    func snapshotIsConsistent() {
        let counters = RecordingCounters()
        counters.begin(sampleRate: 32_000)
        counters.add(frames: 16_000)

        let snapshot = counters.snapshot()
        #expect(snapshot.frames == 16_000)
        #expect(snapshot.sampleRate == 32_000)
    }

    // MARK: - The contract that matters

    @Test("every frame added concurrently is counted exactly once")
    func concurrentAddsAreExact() async {
        let counters = RecordingCounters()
        counters.begin(sampleRate: 48_000)

        let writers = 8
        let addsPerWriter = 2_000

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<writers {
                group.addTask {
                    for _ in 0..<addsPerWriter { counters.add(frames: 1) }
                }
            }
        }

        #expect(counters.writtenFrames == Int64(writers * addsPerWriter))
    }

    /// The regression this whole type exists for.
    ///
    /// `MicSource`'s tap holds its engine lock across downmix, AAC conversion
    /// and the file write, and the record screen polls `recordedDuration` on
    /// the main actor ten times a second. While the frame counter lived behind
    /// that same lock, a poll could block the main thread for the length of a
    /// disk write — and a main thread that stalls stops drawing the window,
    /// which is what made the sidebar appear to vanish once recording started.
    ///
    /// Here a writer holds a *separate* lock — standing in for the engine lock
    /// — for a long time while doing its slow "write", and updates the counters
    /// from inside it. A reader must still get an answer promptly. If
    /// `duration` ever went back to sharing the writer's lock, this test would
    /// take as long as the simulated writes and blow its deadline.
    @Test("a reader is not blocked by a writer holding the engine lock", .timeLimit(.minutes(1)))
    func readerIsNotBlockedByTheWritePath() async {
        let counters = RecordingCounters()
        counters.begin(sampleRate: 48_000)

        let engineLock = UnfairLock()
        let slowWriteSeconds = 0.05
        let buffers = 10

        // The writer: the tap's shape exactly — take the engine lock, do
        // something slow with the file, update the counters, release.
        let writer = Task.detached {
            for _ in 0..<buffers {
                engineLock.lock()
                Thread.sleep(forTimeInterval: slowWriteSeconds)
                counters.add(frames: 4_800)
                engineLock.unlock()
                await Task.yield()
            }
        }

        // The reader: the main actor's 10 Hz poll. Every read must return in
        // far less than one slow write.
        let reader = Task.detached { () -> TimeInterval in
            var worst: TimeInterval = 0
            for _ in 0..<200 {
                let start = Date()
                _ = counters.duration
                worst = max(worst, Date().timeIntervalSince(start))
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return worst
        }

        let worstRead = await reader.value
        await writer.value

        #expect(
            worstRead < slowWriteSeconds,
            """
            A read of `duration` took \(worstRead)s, which is at least as long as \
            a simulated write (\(slowWriteSeconds)s) — the counters are sharing a \
            lock with the write path again. That is the main-thread stall that \
            made the window stop redrawing during a recording.
            """
        )

        // And the slow writer's frames still all landed.
        #expect(counters.writtenFrames == Int64(buffers * 4_800))
    }

    @Test("a reader sees a run that is still in progress, not only its end")
    func readerSeesProgress() async {
        let counters = RecordingCounters()
        counters.begin(sampleRate: 48_000)

        counters.add(frames: 48_000)
        let midRun = counters.duration
        counters.add(frames: 48_000)
        let later = counters.duration

        #expect(midRun == 1.0)
        #expect(later == 2.0)
        #expect(later > midRun)
    }
}
