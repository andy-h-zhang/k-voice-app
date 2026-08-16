import Foundation

/// Every setting from spec §Settings **except** the API key, which is
/// Keychain-only (``APIKeyStore``) and never touches `UserDefaults`.
///
/// A value snapshot rather than a live object, so a `TranscriptionJob` can be
/// handed the settings that were in force **at submit time** and a later edit
/// to the keyterms list cannot retroactively change a request already on the
/// wire (plan §2 Phase 3: "keyterms from settings passed as `keyterms_prompt`").
public struct SettingsSnapshot: Sendable, Equatable {

    /// Where the recording library lives (spec: default `~/Documents/KVoice/`).
    public var storageFolderURL: URL

    /// Cosine similarity required to auto-assign a name. Clamped to
    /// ``SettingsStore/thresholdRange`` on the way in and out.
    public var similarityThreshold: Float

    /// Domain vocabulary sent as `keyterms_prompt`. Stored verbatim; the API's
    /// limits are applied by `TranscriptRequest.sanitizedKeyterms` at submit
    /// time, so a settings list is never silently truncated on save.
    public var keyterms: [String]

    /// CoreAudio device UID of the chosen input, or nil for the system default.
    public var inputDeviceUID: String?

    /// Which speech model — and whether a fallback is allowed — this job asks
    /// for. Part of the snapshot rather than a job "knob" for the same reason
    /// the keyterms are: it is a user setting, and the one in force at submit
    /// time is the one that must govern the request.
    public var speechModelPreference: SpeechModelPreference

    public init(
        storageFolderURL: URL,
        similarityThreshold: Float,
        keyterms: [String],
        inputDeviceUID: String?,
        speechModelPreference: SpeechModelPreference = .default
    ) {
        self.storageFolderURL = storageFolderURL
        self.similarityThreshold = similarityThreshold
        self.keyterms = keyterms
        self.inputDeviceUID = inputDeviceUID
        self.speechModelPreference = speechModelPreference
    }
}

/// `UserDefaults`-backed settings (plan §1: "Settings stored in UserDefaults …
/// not SwiftData. API key in Keychain only.").
///
/// The suite is injectable so tests get an isolated domain and never write to
/// the developer's real preferences — the constructor takes any `UserDefaults`,
/// and ``SettingsStore/ephemeral(name:)`` builds a throwaway one.
///
/// A `final class` marked `@unchecked Sendable`: the only stored state is the
/// `UserDefaults` reference, and `UserDefaults` is documented thread-safe.
public final class SettingsStore: @unchecked Sendable {

    /// Keys, namespaced so they cannot collide with anything the app layer
    /// stores later.
    public enum Key {
        public static let storageFolderPath = "kvoice.settings.storageFolderPath"
        public static let similarityThreshold = "kvoice.settings.similarityThreshold"
        public static let keyterms = "kvoice.settings.keyterms"
        /// Which storage layout the library on disk is in. Absent means the
        /// pre-project layout, whatever the app version.
        public static let libraryLayoutVersion = "kvoice.settings.libraryLayoutVersion"
        public static let inputDeviceUID = "kvoice.settings.inputDeviceUID"
        public static let speechModelPreference = "kvoice.settings.speechModelPreference"
    }

    /// Settings-UI range for the threshold slider (plan §3 decision 7).
    public static let thresholdRange: ClosedRange<Float> = 0.40...0.80

    private let defaults: UserDefaults
    private let defaultStorageFolderURL: URL

    public init(
        defaults: UserDefaults = .standard,
        defaultStorageFolderURL: URL = RecordingStore.defaultRootURL()
    ) {
        self.defaults = defaults
        self.defaultStorageFolderURL = defaultStorageFolderURL
    }

    /// A store over a private, empty suite. Used by tests; `dispose()` removes
    /// the domain again.
    public static func ephemeral(
        name: String = "kvoice.tests.\(UUID().uuidString)",
        defaultStorageFolderURL: URL = RecordingStore.defaultRootURL()
    ) -> SettingsStore {
        let defaults = UserDefaults(suiteName: name) ?? .standard
        return SettingsStore(defaults: defaults, defaultStorageFolderURL: defaultStorageFolderURL)
    }

    /// Forgets every value in this store's suite.
    public func removeAll() {
        for key in [
            Key.storageFolderPath, Key.similarityThreshold, Key.keyterms,
            Key.libraryLayoutVersion, Key.inputDeviceUID, Key.speechModelPreference
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Individual settings

    /// Library root. Falls back to `~/Documents/KVoice` when unset.
    ///
    /// Stored as a path string rather than as an archived `URL` so a user can
    /// read and fix it with `defaults read`, and so a bookmark-shaped value
    /// can be added later without a migration.
    public var storageFolderURL: URL {
        get {
            guard let path = defaults.string(forKey: Key.storageFolderPath),
                !path.trimmingCharacters(in: .whitespaces).isEmpty
            else { return defaultStorageFolderURL }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Key.storageFolderPath) }
    }

    /// Cosine threshold for auto-assigning a name.
    ///
    /// Reads clamp to ``thresholdRange``, so a hand-edited plist holding `9`
    /// degrades to "match nothing beyond 0.80" instead of silently disabling
    /// speaker ID. Unset means the Phase-1 tuned default (0.62).
    public var similarityThreshold: Float {
        get {
            guard defaults.object(forKey: Key.similarityThreshold) != nil else {
                return ClusterMatcher.defaultThreshold
            }
            return Self.clampThreshold(Float(defaults.double(forKey: Key.similarityThreshold)))
        }
        set { defaults.set(Double(Self.clampThreshold(newValue)), forKey: Key.similarityThreshold) }
    }

    /// Keyterms, trimmed and de-duplicated on write. Empty by default.
    public var keyterms: [String] {
        get { defaults.stringArray(forKey: Key.keyterms) ?? [] }
        set {
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            defaults.set(cleaned, forKey: Key.keyterms)
        }
    }

    /// Which storage layout the library on disk is in.
    ///
    /// `0` — and therefore any library written before this key existed — means
    /// the pre-project layout: audio named exactly after its folder, rendered
    /// transcripts in a shared `Transcripts/`. `1` means every recording is a
    /// self-contained project folder. ``LibraryMigration`` is what moves a
    /// library from one to the other, and this is the flag that stops it
    /// walking the whole library on every launch forever after.
    ///
    /// A version rather than a `didMigrate` bool so the next layout change has
    /// somewhere to go.
    public var libraryLayoutVersion: Int {
        get { defaults.integer(forKey: Key.libraryLayoutVersion) }
        set { defaults.set(newValue, forKey: Key.libraryLayoutVersion) }
    }

    /// The layout this build writes.
    public static let currentLibraryLayoutVersion = 1

    /// CoreAudio UID of the selected input device; nil means system default.
    public var inputDeviceUID: String? {
        get {
            let value = defaults.string(forKey: Key.inputDeviceUID)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Key.inputDeviceUID)
            } else {
                defaults.removeObject(forKey: Key.inputDeviceUID)
            }
        }
    }

    /// Which speech model transcription asks for. Unset (or unrecognized) means
    /// ``SpeechModelPreference/default`` — 3.5 Pro with no fallback.
    public var speechModelPreference: SpeechModelPreference {
        get {
            guard let raw = defaults.string(forKey: Key.speechModelPreference),
                let preference = SpeechModelPreference(rawValue: raw)
            else { return .default }
            return preference
        }
        set { defaults.set(newValue.rawValue, forKey: Key.speechModelPreference) }
    }

    // MARK: - Snapshots

    /// Reads every setting at once. This is what a job is constructed with.
    public func snapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            storageFolderURL: storageFolderURL,
            similarityThreshold: similarityThreshold,
            keyterms: keyterms,
            inputDeviceUID: inputDeviceUID,
            speechModelPreference: speechModelPreference
        )
    }

    /// Writes every setting at once.
    public func apply(_ snapshot: SettingsSnapshot) {
        storageFolderURL = snapshot.storageFolderURL
        similarityThreshold = snapshot.similarityThreshold
        keyterms = snapshot.keyterms
        inputDeviceUID = snapshot.inputDeviceUID
    }

    static func clampThreshold(_ value: Float) -> Float {
        guard value.isFinite else { return ClusterMatcher.defaultThreshold }
        return min(thresholdRange.upperBound, max(thresholdRange.lowerBound, value))
    }
}
