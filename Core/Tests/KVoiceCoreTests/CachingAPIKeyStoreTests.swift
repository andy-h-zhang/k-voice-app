import Foundation
import Testing

@testable import KVoiceCore

/// Counts reads, so "how many times did we touch the Keychain" is assertable —
/// which is the whole point of the cache, since every real read is a potential
/// authorization dialog.
private final class CountingAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var deleteCount = 0
    /// When set, `apiKey()` throws it instead of answering.
    var readError: Error?

    init(apiKey: String? = nil) { self.storage = apiKey }

    func apiKey() throws -> String? {
        lock.lock()
        readCount += 1
        let error = readError
        let value = storage
        lock.unlock()
        if let error { throw error }
        return value
    }

    func setAPIKey(_ key: String) throws {
        lock.lock(); writeCount += 1; storage = key; lock.unlock()
    }

    func deleteAPIKey() throws {
        lock.lock(); deleteCount += 1; storage = nil; lock.unlock()
    }
}

private struct Denied: Error {}

@Suite("Caching API key store")
struct CachingAPIKeyStoreTests {

    @Test("reads the underlying store once, however many times it is asked")
    func readsOnce() throws {
        let underlying = CountingAPIKeyStore(apiKey: "abc123")
        let store = CachingAPIKeyStore(underlying)

        for _ in 0..<10 {
            #expect(try store.apiKey() == "abc123")
        }
        #expect(underlying.readCount == 1)
    }

    /// The case that made pressing Transcribe prompt every time: a *missing*
    /// key must be remembered too, or every check re-reads the Keychain.
    @Test("a confirmed absence is cached as firmly as a key")
    func cachesAbsence() throws {
        let underlying = CountingAPIKeyStore(apiKey: nil)
        let store = CachingAPIKeyStore(underlying)

        #expect(try store.apiKey() == nil)
        #expect(try store.apiKey() == nil)
        #expect(try store.apiKey() == nil)
        #expect(underlying.readCount == 1)
    }

    /// Cancelling the dialog or a locked keychain must not become permanent:
    /// the user could never recover without relaunching.
    @Test("a thrown read is not cached, so the next attempt can ask again")
    func doesNotCacheFailures() throws {
        let underlying = CountingAPIKeyStore(apiKey: "abc123")
        underlying.readError = Denied()
        let store = CachingAPIKeyStore(underlying)

        #expect(throws: Denied.self) { _ = try store.apiKey() }
        #expect(underlying.readCount == 1)

        // The user allows it the second time.
        underlying.readError = nil
        #expect(try store.apiKey() == "abc123")
        #expect(underlying.readCount == 2)
    }

    @Test("saving a key updates the cache without another read")
    func writeRefreshesCache() throws {
        let underlying = CountingAPIKeyStore(apiKey: nil)
        let store = CachingAPIKeyStore(underlying)

        #expect(try store.apiKey() == nil)
        try store.setAPIKey("new-key")

        #expect(try store.apiKey() == "new-key")
        #expect(underlying.writeCount == 1)
        #expect(underlying.readCount == 1, "the write already knew the value")
    }

    @Test("removing the key is visible immediately")
    func deleteRefreshesCache() throws {
        let underlying = CountingAPIKeyStore(apiKey: "abc123")
        let store = CachingAPIKeyStore(underlying)

        #expect(try store.apiKey() == "abc123")
        try store.deleteAPIKey()

        #expect(try store.apiKey() == nil)
        #expect(underlying.deleteCount == 1)
        #expect(underlying.readCount == 1)
    }

    @Test("invalidate forces one more read")
    func invalidateForcesReread() throws {
        let underlying = CountingAPIKeyStore(apiKey: "abc123")
        let store = CachingAPIKeyStore(underlying)

        #expect(try store.apiKey() == "abc123")
        store.invalidate()
        #expect(try store.apiKey() == "abc123")
        #expect(underlying.readCount == 2)
    }

    /// `APIKeyResolver` is what every caller actually goes through, so the
    /// saving has to survive that path too.
    @Test("resolving repeatedly still costs one underlying read")
    func resolverBenefits() {
        let underlying = CountingAPIKeyStore(apiKey: "abc123")
        let store = CachingAPIKeyStore(underlying)

        for _ in 0..<5 {
            #expect(APIKeyResolver.resolve(environment: [:], keychain: store) == "abc123")
        }
        #expect(underlying.readCount == 1)
    }

    /// The environment variable wins, and when it does the Keychain should not
    /// be touched at all — no read, so no dialog.
    @Test("an environment key short-circuits before the Keychain is read")
    func environmentAvoidsKeychainEntirely() {
        let underlying = CountingAPIKeyStore(apiKey: "from-keychain")
        let store = CachingAPIKeyStore(underlying)

        let resolved = APIKeyResolver.resolve(
            environment: [APIKeyResolver.environmentVariable: "from-env"],
            keychain: store
        )

        #expect(resolved == "from-env")
        #expect(underlying.readCount == 0)
    }
}
