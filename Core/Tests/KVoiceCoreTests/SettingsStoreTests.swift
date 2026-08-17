import Foundation
import Security
import Testing

@testable import KVoiceCore

/// A `SettingsStore` over a throwaway `UserDefaults` suite.
///
/// The injectable suite is the whole reason these tests can run at all: a
/// store over `.standard` would write into the developer's own preferences.
private struct SettingsSuite {
    let name: String
    let defaults: UserDefaults
    let store: SettingsStore
    let defaultRoot = URL(fileURLWithPath: "/tmp/KVoiceDefaultLibrary", isDirectory: true)

    init() {
        name = "kvoice.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name) ?? .standard
        store = SettingsStore(defaults: defaults, defaultStorageFolderURL: defaultRoot)
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

@Suite("Settings store")
struct SettingsStoreTests {

    @Test("an untouched store answers with the documented defaults")
    func defaults() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        #expect(suite.store.storageFolderURL == suite.defaultRoot)
        #expect(suite.store.similarityThreshold == ClusterMatcher.defaultThreshold)
        #expect(suite.store.keyterms.isEmpty)
        #expect(suite.store.libraryLayoutVersion == 0)
        #expect(suite.store.inputDeviceUID == nil)
        #expect(suite.store.themeID == .system)
        #expect(suite.store.appearanceMode == .system)
    }

    @Test("theme and appearance round-trip")
    func themeRoundTrip() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        suite.store.themeID = .aurora
        suite.store.appearanceMode = .dark

        let reader = SettingsStore(defaults: suite.defaults, defaultStorageFolderURL: suite.defaultRoot)
        #expect(reader.themeID == .aurora)
        #expect(reader.appearanceMode == .dark)
    }

    @Test("an unrecognized stored theme or mode degrades to system, not a crash")
    func themeGarbageDegrades() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        // A theme removed in a later version, or a hand-edited plist: the
        // stale string must read as the native look.
        suite.defaults.set("solarpunk", forKey: SettingsStore.Key.themeID)
        suite.defaults.set("sepia", forKey: SettingsStore.Key.appearanceMode)
        #expect(suite.store.themeID == .system)
        #expect(suite.store.appearanceMode == .system)
    }

    @Test("the real default library root is ~/Documents/KVoice")
    func realDefaultRoot() {
        #expect(RecordingStore.defaultRootURL().lastPathComponent == "KVoice")
    }

    @Test("every setting round-trips")
    func roundTrip() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        let folder = URL(fileURLWithPath: "/Users/somebody/Meetings", isDirectory: true)
        suite.store.storageFolderURL = folder
        suite.store.similarityThreshold = 0.71
        suite.store.keyterms = ["Kizaki", "KVoice"]
        suite.store.libraryLayoutVersion = 1
        suite.store.inputDeviceUID = "AppleUSBAudioEngine:Blue:Yeti"

        #expect(suite.store.storageFolderURL.path == folder.path)
        #expect(abs(suite.store.similarityThreshold - 0.71) < 1e-6)
        #expect(suite.store.keyterms == ["Kizaki", "KVoice"])
        #expect(suite.store.libraryLayoutVersion == 1)
        #expect(suite.store.inputDeviceUID == "AppleUSBAudioEngine:Blue:Yeti")

        // A second store over the same suite reads the same values, which is
        // what "settings take effect without a relaunch" rests on.
        let reader = SettingsStore(defaults: suite.defaults, defaultStorageFolderURL: suite.defaultRoot)
        #expect(reader.snapshot() == suite.store.snapshot())
    }

    @Test("a stored path with a tilde is expanded on the way out")
    func tildeExpansion() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        suite.defaults.set("~/Documents/Elsewhere", forKey: SettingsStore.Key.storageFolderPath)
        #expect(!suite.store.storageFolderURL.path.contains("~"))
        #expect(suite.store.storageFolderURL.lastPathComponent == "Elsewhere")
    }

    @Test("a blank stored path falls back to the default rather than to /")
    func blankPath() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        suite.defaults.set("   ", forKey: SettingsStore.Key.storageFolderPath)
        #expect(suite.store.storageFolderURL == suite.defaultRoot)
    }

    @Test("the threshold is clamped into the settings slider's range")
    func thresholdClamping() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        suite.store.similarityThreshold = 0.1
        #expect(suite.store.similarityThreshold == SettingsStore.thresholdRange.lowerBound)

        suite.store.similarityThreshold = 0.99
        #expect(suite.store.similarityThreshold == SettingsStore.thresholdRange.upperBound)

        // A hand-edited plist must degrade, not disable speaker ID.
        suite.defaults.set(9.0, forKey: SettingsStore.Key.similarityThreshold)
        #expect(suite.store.similarityThreshold == SettingsStore.thresholdRange.upperBound)

        suite.defaults.set(Double.nan, forKey: SettingsStore.Key.similarityThreshold)
        #expect(suite.store.similarityThreshold == ClusterMatcher.defaultThreshold)
    }

    @Test("the slider range brackets the Phase-1 default")
    func thresholdRange() {
        #expect(SettingsStore.thresholdRange == 0.40...0.80)
        #expect(SettingsStore.thresholdRange.contains(ClusterMatcher.defaultThreshold))
    }

    @Test("keyterms are trimmed and de-duplicated on write")
    func keytermHygiene() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        suite.store.keyterms = ["  Kizaki  ", "", "   ", "kizaki", "KVoice"]
        #expect(suite.store.keyterms == ["Kizaki", "KVoice"])
    }

    @Test("keyterms are stored raw, so the API's limits are applied at submit time")
    func keytermsNotTruncatedOnSave() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        // Over-long for the API, but a settings list is not the place to
        // silently drop what the user typed.
        let long = "this phrase has far too many words to be a valid keyterm"
        suite.store.keyterms = [long]
        #expect(suite.store.keyterms == [long])
        #expect(TranscriptRequest.sanitizedKeyterms(suite.store.keyterms).isEmpty)
    }

    @Test("clearing the input device UID removes it rather than storing an empty string")
    func clearInputDevice() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        suite.store.inputDeviceUID = "device-1"
        suite.store.inputDeviceUID = nil
        #expect(suite.store.inputDeviceUID == nil)

        suite.store.inputDeviceUID = "device-2"
        suite.store.inputDeviceUID = ""
        #expect(suite.store.inputDeviceUID == nil)
    }

    /// The flag that decides whether ``LibraryMigration`` walks the library on
    /// launch. A library written before the key existed reads `0`, which is
    /// exactly right: it has not been migrated.
    @Test("the layout version round-trips, and defaults to unmigrated")
    func layoutVersionPersistence() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        #expect(suite.store.libraryLayoutVersion == 0)

        suite.store.libraryLayoutVersion = SettingsStore.currentLibraryLayoutVersion
        #expect(suite.store.libraryLayoutVersion == 1)

        let reader = SettingsStore(defaults: suite.defaults, defaultStorageFolderURL: suite.defaultRoot)
        #expect(reader.libraryLayoutVersion == 1)
    }

    @Test("a snapshot applies wholesale onto another suite")
    func snapshotApply() {
        let source = SettingsSuite()
        let destination = SettingsSuite()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }

        source.store.storageFolderURL = URL(fileURLWithPath: "/tmp/Recordings", isDirectory: true)
        source.store.similarityThreshold = 0.55
        source.store.keyterms = ["Kizaki"]
        source.store.inputDeviceUID = "device-9"

        destination.store.apply(source.store.snapshot())
        #expect(destination.store.snapshot() == source.store.snapshot())
    }

    @Test("suites are isolated from one another")
    func suiteIsolation() {
        let first = SettingsSuite()
        let second = SettingsSuite()
        defer {
            first.cleanUp()
            second.cleanUp()
        }

        first.store.similarityThreshold = 0.75
        #expect(second.store.similarityThreshold == ClusterMatcher.defaultThreshold)
    }

    @Test("removeAll restores the defaults")
    func removeAll() {
        let suite = SettingsSuite()
        defer { suite.cleanUp() }

        suite.store.similarityThreshold = 0.75
        suite.store.keyterms = ["Kizaki"]
        suite.store.inputDeviceUID = "device-1"
        suite.store.themeID = .lagoon
        suite.store.appearanceMode = .light
        suite.store.removeAll()

        #expect(suite.store.similarityThreshold == ClusterMatcher.defaultThreshold)
        #expect(suite.store.keyterms.isEmpty)
        #expect(suite.store.inputDeviceUID == nil)
        #expect(suite.store.storageFolderURL == suite.defaultRoot)
        #expect(suite.store.themeID == .system)
        #expect(suite.store.appearanceMode == .system)
    }

    @Test("an ephemeral store starts empty")
    func ephemeral() {
        let store = SettingsStore.ephemeral(
            defaultStorageFolderURL: URL(fileURLWithPath: "/tmp/X", isDirectory: true)
        )
        #expect(store.keyterms.isEmpty)
        #expect(store.similarityThreshold == ClusterMatcher.defaultThreshold)
        store.removeAll()
    }
}

// MARK: - API key storage

/// A store that always fails, standing in for a locked or denied Keychain.
private struct FailingAPIKeyStore: APIKeyStore {
    func apiKey() throws -> String? { throw KeychainError.status(errSecInteractionNotAllowed) }
    func setAPIKey(_ key: String) throws { throw KeychainError.status(errSecInteractionNotAllowed) }
    func deleteAPIKey() throws { throw KeychainError.status(errSecInteractionNotAllowed) }
}

@Suite("API key storage and resolution")
struct APIKeyStoreTests {

    @Test("the in-memory store gets, sets, and deletes")
    func inMemory() throws {
        let store = InMemoryAPIKeyStore()
        #expect(try store.apiKey() == nil)

        try store.setAPIKey("secret-1")
        #expect(try store.apiKey() == "secret-1")

        try store.setAPIKey("secret-2")
        #expect(try store.apiKey() == "secret-2")

        try store.deleteAPIKey()
        #expect(try store.apiKey() == nil)
        // Deleting again is the caller's desired end state, not an error.
        try store.deleteAPIKey()
    }

    @Test("the null store holds nothing and swallows writes")
    func nullStore() throws {
        let store = NullAPIKeyStore()
        try store.setAPIKey("ignored")
        #expect(try store.apiKey() == nil)
        try store.deleteAPIKey()
    }

    @Test("the environment variable wins over a stored key")
    func environmentWins() {
        let keychain = InMemoryAPIKeyStore(apiKey: "from-keychain")
        let key = APIKeyResolver.resolve(
            environment: ["ASSEMBLYAI_API_KEY": "from-environment"],
            keychain: keychain
        )
        #expect(key == "from-environment")
    }

    @Test("an absent or blank environment variable falls back to the Keychain")
    func keychainFallback() {
        let keychain = InMemoryAPIKeyStore(apiKey: "from-keychain")
        #expect(APIKeyResolver.resolve(environment: [:], keychain: keychain) == "from-keychain")
        #expect(
            APIKeyResolver.resolve(
                environment: ["ASSEMBLYAI_API_KEY": "   "], keychain: keychain
            ) == "from-keychain"
        )
    }

    @Test("keys are trimmed, from either source")
    func trimming() {
        #expect(
            APIKeyResolver.resolve(environment: ["ASSEMBLYAI_API_KEY": "  abc  "]) == "abc"
        )
        #expect(
            APIKeyResolver.resolve(
                environment: [:], keychain: InMemoryAPIKeyStore(apiKey: "\n def \n")
            ) == "def"
        )
    }

    @Test("with no key anywhere, resolution is nil and require throws")
    func noKeyAnywhere() {
        #expect(APIKeyResolver.resolve(environment: [:], keychain: InMemoryAPIKeyStore()) == nil)
        #expect(throws: TranscriptionError.missingAPIKey) {
            try APIKeyResolver.require(environment: [:], keychain: InMemoryAPIKeyStore())
        }
    }

    @Test("a Keychain that refuses to answer is treated as having no key")
    func keychainFailureIsNotFatal() {
        // Locked, denied, or otherwise unavailable: the user's next move is
        // the same as if it were empty, and `missingAPIKey` already says it.
        #expect(APIKeyResolver.resolve(environment: [:], keychain: FailingAPIKeyStore()) == nil)
        #expect(
            APIKeyResolver.resolve(
                environment: ["ASSEMBLYAI_API_KEY": "abc"], keychain: FailingAPIKeyStore()
            ) == "abc"
        )
    }

    @Test("the missing-key message names the variable and where the app stores it")
    func guidanceIsActionable() throws {
        // There is no API key anywhere yet, so this text is the first thing a
        // user will see. It has to be enough to act on without reading code.
        let message = try #require(TranscriptionError.missingAPIKey.errorDescription)
        #expect(message.contains("ASSEMBLYAI_API_KEY"))
        #expect(message.contains("Keychain"))
        #expect(message.contains(KeychainAPIKeyStore.defaultService))
        #expect(message.contains(KeychainAPIKeyStore.defaultAccount))
        #expect(message.contains("assemblyai.com"))
        // Precedence is stated, because both sources can hold a key.
        #expect(message.contains("always wins"))
    }

    @Test("a rejected key points at both places it could have come from")
    func unauthorizedIsActionable() throws {
        let message = try #require(
            TranscriptionError.unauthorized(message: "bad key").errorDescription
        )
        #expect(message.contains("401"))
        #expect(message.contains("ASSEMBLYAI_API_KEY"))
        #expect(message.contains("Settings"))
    }
}

@Suite("Client key resolution")
struct ClientKeyResolutionTests {

    @Test("resolved() builds a client from the environment")
    func fromEnvironment() throws {
        _ = try AssemblyAIClient.resolved(
            environment: ["ASSEMBLYAI_API_KEY": "abc"],
            keychain: InMemoryAPIKeyStore()
        )
    }

    @Test("resolved() falls back to the Keychain")
    func fromKeychain() throws {
        _ = try AssemblyAIClient.resolved(
            environment: [:],
            keychain: InMemoryAPIKeyStore(apiKey: "stored-key")
        )
    }

    @Test("resolved() throws the actionable error when neither source has a key")
    func noKey() {
        #expect(throws: TranscriptionError.missingAPIKey) {
            try AssemblyAIClient.resolved(environment: [:], keychain: InMemoryAPIKeyStore())
        }
    }

    @Test("fromEnvironment stays environment-only, so tests never reach a Keychain")
    func fromEnvironmentIgnoresKeychain() {
        // Phase 1 fixed this contract; the Keychain fallback is opt-in via
        // `resolved`, which is what keeps the test suite prompt-free.
        #expect(throws: TranscriptionError.missingAPIKey) {
            try AssemblyAIClient.fromEnvironment(environment: [:])
        }
    }
}

@Suite("Keychain wrapper")
struct KeychainAPIKeyStoreTests {

    // No test here calls SecItemAdd/CopyMatching: an unsigned test binary has
    // no stable keychain identity, so a real read or write can raise a system
    // dialog or fail with errSecMissingEntitlement. What is decidable without
    // the daemon is tested; the behavior that depends on this type is covered
    // through `APIKeyStore` with `InMemoryAPIKeyStore`.

    @Test("the query addresses one generic-password item")
    func queryShape() {
        let query = KeychainAPIKeyStore.baseQuery(service: "svc", account: "acct")

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "svc")
        #expect(query[kSecAttrAccount as String] as? String == "acct")
        // Nothing else: every operation starts from this, so a lookup can
        // never disagree with a write about what it addresses.
        #expect(query.count == 3)
    }

    @Test("a write carries the value and the ACL that keeps reads silent")
    func addQueryShape() throws {
        let access = try #require(
            KeychainAPIKeyStore.selfTrustingAccess(descriptor: "test"),
            "SecAccessCreate should succeed even from an unsigned test binary"
        )
        let query = KeychainAPIKeyStore.addQuery(
            service: "svc",
            account: "acct",
            data: Data("secret".utf8),
            access: access
        )

        // Still addresses the same item as every read.
        #expect(query[kSecAttrService as String] as? String == "svc")
        #expect(query[kSecAttrAccount as String] as? String == "acct")
        #expect(query[kSecValueData as String] as? Data == Data("secret".utf8))

        // The ACL is the whole point: without it the item trusts nobody and
        // every read raises the password dialog.
        #expect(query[kSecAttrAccess as String] != nil)
        // `kSecAttrAccessible` alongside `kSecAttrAccess` is `errSecParam`.
        #expect(query[kSecAttrAccessible as String] == nil)
    }

    @Test("a write without an ACL still stores the key")
    func addQueryWithoutAccess() {
        // SecAccessCreate failing must degrade to prompting, not to losing the
        // user's key.
        let query = KeychainAPIKeyStore.addQuery(
            service: "svc",
            account: "acct",
            data: Data("secret".utf8),
            access: nil
        )

        #expect(query[kSecValueData as String] as? Data == Data("secret".utf8))
        #expect(query[kSecAttrAccess as String] == nil)
    }

    @Test("the defaults are the documented service and account")
    func defaults() {
        let store = KeychainAPIKeyStore()
        #expect(store.service == "ai.kizaki.KVoice")
        #expect(store.account == "assemblyai-api-key")
        #expect(store.service == KeychainAPIKeyStore.defaultService)
        #expect(store.account == KeychainAPIKeyStore.defaultAccount)
    }

    @Test("access-denied statuses are distinguished from real breakage")
    func accessDenied() {
        #expect(KeychainError.status(errSecUserCanceled).isAccessDenied)
        #expect(KeychainError.status(errSecAuthFailed).isAccessDenied)
        #expect(KeychainError.status(errSecInteractionNotAllowed).isAccessDenied)
        #expect(KeychainError.status(errSecInteractionRequired).isAccessDenied)

        #expect(!KeychainError.status(errSecItemNotFound).isAccessDenied)
        #expect(!KeychainError.unexpectedItemFormat.isAccessDenied)
    }

    @Test("every Keychain error describes itself")
    func descriptions() throws {
        let status = try #require(KeychainError.status(errSecItemNotFound).errorDescription)
        #expect(status.contains("\(errSecItemNotFound)"))
        #expect(try #require(KeychainError.unexpectedItemFormat.errorDescription).contains("readable text"))
    }
}
