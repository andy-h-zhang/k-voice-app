import Foundation
import SwiftData

/// The SwiftData schema and the one place a `ModelContainer` is built.
///
/// Two shapes, per plan §2 Phase 3 ("`ModelContainer` setup shared by app and,
/// in tests, in-memory"):
///
/// - ``onDisk(at:)`` — the app's store. Lives beside the recording library so
///   a user who moves or backs up the folder takes the database with it.
/// - ``inMemory()`` — a throwaway store per test, which is what keeps the
///   suite offline, parallel-safe, and free of cross-test bleed.
public enum KVoiceSchema {

    /// Default file name of the on-disk store.
    public static let storeFileName = "KVoice.store"

    /// Every `@Model` type in the schema. Adding a model here is the only step
    /// needed to include it in both containers.
    public static var models: [any PersistentModel.Type] {
        [
            Recording.self,
            Utterance.self,
            SpeakerSlot.self,
            Person.self,
            PersonEmbedding.self
        ]
    }

    public static var schema: Schema {
        Schema(models)
    }

    /// A container backed by a file.
    ///
    /// - Parameter url: The store file. Defaults to
    ///   `<library root>/KVoice.store` when a root is supplied, otherwise
    ///   Application Support.
    public static func onDisk(at url: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// A container for the store inside a recording-library root.
    public static func onDisk(inLibraryRoot root: URL) throws -> ModelContainer {
        try onDisk(at: root.appendingPathComponent(storeFileName))
    }

    /// The default on-disk location, `~/Library/Application Support/KVoice/`.
    public static func defaultStoreURL(appName: String = "KVoice") -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent(storeFileName)
    }

    /// A container that never touches the disk. Every test gets its own.
    public static func inMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

// MARK: - Context helpers

extension ModelContext {

    /// Fetches the recording with this id, or nil.
    ///
    /// A `#Predicate` on the stored `id` rather than a fetch-everything-filter,
    /// so the library can grow without every lookup scanning it.
    public func recording(id: UUID) throws -> Recording? {
        var descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// Fetches the person with this id, or nil.
    public func person(id: UUID) throws -> Person? {
        var descriptor = FetchDescriptor<Person>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// Case-insensitive name lookup, matching `ProfileLibrary.profile(named:)`
    /// so the JSON and SwiftData profile sources agree on identity.
    ///
    /// SwiftData predicates cannot express the trim-and-lowercase comparison
    /// the JSON store uses, so this fetches candidates by a case-insensitive
    /// `localizedStandardContains` narrowing and settles it in Swift.
    public func person(named name: String) throws -> Person? {
        let key = Self.nameKey(name)
        guard !key.isEmpty else { return nil }
        let all = try fetch(FetchDescriptor<Person>())
        return all.first { Self.nameKey($0.name) == key }
    }

    /// Recordings whose job was still in flight — what a relaunch resumes.
    public func inFlightRecordings() throws -> [Recording] {
        let inFlight = Set(
            RecordingStatus.Kind.allCases
                .filter { RecordingStatus(kind: $0, failureMessage: nil).isInFlight }
                .map(\.rawValue)
        )
        let descriptor = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.statusChangedAt)]
        )
        return try fetch(descriptor).filter { inFlight.contains($0.statusKindRaw) }
    }

    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
