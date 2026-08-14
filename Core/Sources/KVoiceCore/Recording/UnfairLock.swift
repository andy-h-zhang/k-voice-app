import Foundation
import os

/// A minimal `os_unfair_lock` wrapper.
///
/// Two reasons this exists instead of `NSLock`:
///
/// 1. `NSLock.lock()`/`unlock()` are annotated unavailable from asynchronous
///    contexts — a warning today, an error under the Swift 6 language mode —
///    and the recording engine locks from both `async` control methods and a
///    CoreAudio tap callback.
/// 2. `os_unfair_lock` is cheaper for the sub-microsecond critical sections
///    in that callback, and donates priority to the lock holder rather than
///    letting an audio thread spin behind a lower-priority one.
///
/// The lock lives in heap storage because `os_unfair_lock` must never be
/// copied — a struct field would be copied by any `self` capture.
final class UnfairLock: @unchecked Sendable {
    private let storage: os_unfair_lock_t

    init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func lock() {
        os_unfair_lock_lock(storage)
    }

    func unlock() {
        os_unfair_lock_unlock(storage)
    }

    /// Runs `body` with the lock held.
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
