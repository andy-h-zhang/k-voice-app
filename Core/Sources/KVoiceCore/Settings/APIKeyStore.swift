import Foundation

/// Storage for the AssemblyAI API key.
///
/// Spec §Settings: "AssemblyAI API key (Keychain-stored, pasted by the user)".
/// The protocol exists so that (a) the CLI can fall back to the Keychain
/// without linking its own Security code, and (b) tests can exercise the
/// resolution order against a fake — a real Keychain read from an unsigned
/// `xctest` binary is the kind of thing that pops a system dialog on someone's
/// machine, which a test suite must never do.
public protocol APIKeyStore: Sendable {
    /// The stored key, or nil when none has been saved.
    func apiKey() throws -> String?
    /// Stores (or replaces) the key.
    func setAPIKey(_ key: String) throws
    /// Removes the key. Removing an absent key is not an error.
    func deleteAPIKey() throws
}

/// An `APIKeyStore` held in memory. Tests and previews only.
public final class InMemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    public init(apiKey: String? = nil) {
        self.storage = apiKey
    }

    public func apiKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func setAPIKey(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage = key
    }

    public func deleteAPIKey() throws {
        lock.lock()
        defer { lock.unlock() }
        storage = nil
    }
}

/// An `APIKeyStore` that always answers "nothing stored" and refuses writes.
///
/// The default for code paths that must not touch the Keychain — notably
/// `AssemblyAIClient.fromEnvironment`, whose behavior Phase 1 fixed as
/// environment-only.
public struct NullAPIKeyStore: APIKeyStore {
    public init() {}
    public func apiKey() throws -> String? { nil }
    public func setAPIKey(_ key: String) throws {}
    public func deleteAPIKey() throws {}
}

// MARK: - Resolution

/// Decides which API key to use.
///
/// Order is **environment first, Keychain second**, which is what keeps the
/// CLI's documented contract intact: `ASSEMBLYAI_API_KEY` still wins, so a
/// one-off `ASSEMBLYAI_API_KEY=… speakerlab transcribe …` overrides whatever
/// the app saved, and scripts that set it behave exactly as before. The
/// Keychain is only consulted when the variable is absent or blank.
public enum APIKeyResolver {

    public static let environmentVariable = "ASSEMBLYAI_API_KEY"

    /// The one place the "how do I supply a key?" wording lives.
    ///
    /// Every path that needs a key and hasn't got one ends up printing this —
    /// the CLI through `TranscriptionError.missingAPIKey`, the app through the
    /// same error surfaced on a failed `Recording`. Naming both sources and
    /// their precedence matters because there is no key anywhere yet: the
    /// first person to hit this message has to be able to act on it without
    /// reading the source.
    public static let guidance = """
        Supply one of:
          • \(environmentVariable) in the environment \
        (e.g. export \(environmentVariable)=<key>) — this always wins, and is what \
        `speakerlab transcribe` expects;
          • a key saved in the app's Settings, which stores it in the login \
        Keychain (service "\(KeychainAPIKeyStore.defaultService)", account \
        "\(KeychainAPIKeyStore.defaultAccount)") and is used whenever the \
        environment variable is unset.
        Keys are issued at https://www.assemblyai.com/dashboard.
        """

    /// - Returns: The first non-blank key found, or nil.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: any APIKeyStore = NullAPIKeyStore()
    ) -> String? {
        if let fromEnvironment = normalize(environment[environmentVariable]) {
            return fromEnvironment
        }
        // A Keychain that errors (locked, denied) is treated as "no key": the
        // caller's next move is the same either way, and the message it shows
        // is `missingAPIKey`, which already tells the user what to do.
        return normalize(try? keychain.apiKey())
    }

    /// `resolve`, but throwing the error the rest of the stack understands.
    public static func require(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: any APIKeyStore = NullAPIKeyStore()
    ) throws -> String {
        guard let key = resolve(environment: environment, keychain: keychain) else {
            throw TranscriptionError.missingAPIKey
        }
        return key
    }

    static func normalize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
