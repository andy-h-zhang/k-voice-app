import Foundation

/// Reads the key from the store beneath it **once**, then answers from memory.
///
/// ## Why this exists
///
/// Every read of the macOS file-based Keychain is an authorization check
/// against the item's ACL, and when that check does not pass the user gets a
/// password dialog. `TranscriptionCoordinator` calls
/// ``APIKeyResolver/resolve(environment:keychain:)`` on *every* `enqueue`, and
/// again for `canTranscribe`, so pressing Transcribe five times meant five
/// checks — and, on a build the ACL does not trust, five dialogs.
///
/// Caching collapses that to one check per launch. It does not make an
/// untrusted build trusted — that is a code-signing problem and this cannot fix
/// it (see ``KeychainAPIKeyStore``, which mints an ACL that covers the usual
/// case) — but it is the difference between one prompt when you first
/// transcribe and a prompt every single time.
///
/// ## What is deliberately *not* cached
///
/// A **thrown** read. Cancelling the dialog, a locked keychain, and a denied
/// ACL all surface as errors, and remembering them would mean the user could
/// never recover without relaunching: the next attempt must be allowed to ask
/// again. Only a definite answer — a key, or a confirmed absence — is kept.
///
/// ## Security
///
/// No secret lives anywhere it did not already live. The key was always held in
/// process memory while a request was built; this keeps it there between
/// requests instead of fetching it again. It is never written to disk, and it
/// dies with the process.
public final class CachingAPIKeyStore: APIKeyStore, @unchecked Sendable {

    private let underlying: any APIKeyStore
    private let lock = NSLock()

    /// Doubly optional on purpose: the outer `nil` means "never read", the
    /// inner `nil` means "read, and there is no key". Collapsing the two would
    /// re-read the Keychain — and re-prompt — on every check once a user has
    /// removed their key.
    private var cached: String??

    public init(_ underlying: any APIKeyStore) {
        self.underlying = underlying
    }

    public func apiKey() throws -> String? {
        lock.lock()
        let hit = cached
        lock.unlock()
        if let hit { return hit }

        // Deliberately outside the lock: this call can put a modal dialog on
        // screen and block for as long as the user takes to answer it, and a
        // lock held across that would take every other reader with it.
        let value = try underlying.apiKey()

        lock.lock()
        cached = value
        lock.unlock()
        return value
    }

    public func setAPIKey(_ key: String) throws {
        try underlying.setAPIKey(key)
        lock.lock()
        cached = .some(key)
        lock.unlock()
    }

    public func deleteAPIKey() throws {
        try underlying.deleteAPIKey()
        lock.lock()
        cached = .some(nil)
        lock.unlock()
    }

    /// Forgets what was read, so the next call asks the Keychain again.
    ///
    /// For the case this type cannot see: the item changed underneath it,
    /// edited in Keychain Access or written by another copy of the app.
    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
