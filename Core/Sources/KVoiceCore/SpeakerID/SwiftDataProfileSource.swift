import Foundation
import SwiftData

/// A `ProfileSource` backed by SwiftData `Person` / `PersonEmbedding` rows —
/// the app's profile library.
///
/// ## Why an actor with a context per operation
///
/// `ModelContainer` is `Sendable`; `ModelContext` is not, and a context is
/// cheap. So every operation opens its own context, does its work, saves, and
/// lets it go — the boring solution plan-wise, and the only one that stays
/// correct under actor reentrancy. Two rules make it airtight:
///
/// 1. Contexts never escape ``withContext(_:)``, and its body is
///    **synchronous** — there is no suspension point at which the actor could
///    be reentered while a context is live.
/// 2. Everything crossing the boundary is a `Sendable` value
///    (`ProfileLibrary`, `ProfileFoldOutcome`), never a `PersistentModel`.
///
/// Autosave is off: a fold-in is one atomic save, so a throw part-way leaves
/// the store exactly as it was.
public actor SwiftDataProfileSource: ProfileLearningSource {

    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - ProfileSource

    /// Every person as a `SpeakerProfile`, in creation order.
    ///
    /// `ClusterMatcher` scores against this exactly as it scores the CLI's
    /// JSON library — that identity is the point of the protocol.
    public func library() async throws -> ProfileLibrary {
        try withContext { context in
            let people = try context.fetch(
                FetchDescriptor<Person>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.name)])
            )
            return ProfileLibrary(profiles: people.map(\.profile))
        }
    }

    // MARK: - ProfileLearningSource

    @discardableResult
    public func foldIn(
        _ vector: [Float],
        intoProfileNamed name: String,
        source: EmbeddingSource,
        at date: Date = Date(),
        cap: Int = ProfileFoldPolicy.defaultCap
    ) async throws -> ProfileFoldOutcome {
        try withContext { context in
            let (person, created) = try Self.upsertPerson(named: name, in: context, now: date)
            let evicted = Self.foldIn(vector, into: person, source: source, at: date, cap: cap, in: context)
            // Flush before counting: inserts and deletes are only guaranteed to
            // be reflected in the relationship array once the context is saved.
            try context.save()

            return ProfileFoldOutcome(
                profileID: person.id,
                name: person.name,
                created: created,
                stored: ProfileFoldPolicy.storableVector(vector) != nil,
                embeddingCount: person.embeddings.count,
                evictedCount: evicted
            )
        }
    }

    /// `foldIn` addressed by row identity rather than by name.
    ///
    /// The app's path: the editor already holds the `Person` a `SpeakerSlot`
    /// was assigned to, and going back through a name would re-run the
    /// case-insensitive lookup and could land on a different row if two people
    /// share a spelling.
    @discardableResult
    public func foldIn(
        _ vector: [Float],
        intoPersonWithID personID: UUID,
        source: EmbeddingSource,
        at date: Date = Date(),
        cap: Int = ProfileFoldPolicy.defaultCap
    ) async throws -> ProfileFoldOutcome {
        try withContext { context in
            guard let person = try context.person(id: personID) else {
                throw ProfileSourceError.personNotFound(id: personID)
            }
            let evicted = Self.foldIn(vector, into: person, source: source, at: date, cap: cap, in: context)
            try context.save()
            return ProfileFoldOutcome(
                profileID: person.id,
                name: person.name,
                created: false,
                stored: ProfileFoldPolicy.storableVector(vector) != nil,
                embeddingCount: person.embeddings.count,
                evictedCount: evicted
            )
        }
    }

    @discardableResult
    public func resetLearnedVoice(forProfileNamed name: String) async throws -> Int {
        try withContext { context in
            guard let person = try context.person(named: name) else { return 0 }
            let learned = person.embeddings.filter { $0.source == .autolearn }
            for embedding in learned { context.delete(embedding) }
            return learned.count
        }
    }

    // MARK: - People management

    /// Creates a person if the name is new; returns the row's id either way.
    @discardableResult
    public func upsertPerson(named name: String, at date: Date = Date()) async throws -> UUID {
        try withContext { context in
            try Self.upsertPerson(named: name, in: context, now: date).person.id
        }
    }

    /// Bulk enrollment: one call per clip window, all under one save.
    /// Mirrors `SpeakerProfile.foldIn(contentsOf:…)`.
    @discardableResult
    public func foldIn(
        contentsOf vectors: [[Float]],
        intoProfileNamed name: String,
        source: EmbeddingSource,
        at date: Date = Date(),
        cap: Int = ProfileFoldPolicy.defaultCap
    ) async throws -> ProfileFoldOutcome {
        try withContext { context in
            let (person, created) = try Self.upsertPerson(named: name, in: context, now: date)
            var evicted = 0
            var stored = false
            for vector in vectors {
                if ProfileFoldPolicy.storableVector(vector) != nil { stored = true }
                evicted += Self.foldIn(
                    vector, into: person, source: source, at: date, cap: cap, in: context
                )
            }
            try context.save()
            return ProfileFoldOutcome(
                profileID: person.id,
                name: person.name,
                created: created,
                stored: stored,
                embeddingCount: person.embeddings.count,
                evictedCount: evicted
            )
        }
    }

    /// Removes a person and their embeddings. Speaker slots that resolved to
    /// them are nullified, not deleted — transcripts survive.
    public func deletePerson(id: UUID) async throws {
        try withContext { context in
            guard let person = try context.person(id: id) else { return }
            context.delete(person)
        }
    }

    // MARK: - People directory (Phase 6)
    //
    // Everything below backs the People UI (spec §Voice profiles: "Per-profile
    // actions: rename, re-enroll, delete, reset learned voice"). They are here
    // rather than in the app layer for two reasons: the app cannot hold a
    // `ModelContext` for `Person` without duplicating this actor's
    // context-per-operation discipline, and every rule they encode — name
    // identity, what "re-enroll" clears, what "reset" keeps — has to agree with
    // the fold-in path directly above or the two will drift.

    /// Every person as a display summary, in creation order.
    ///
    /// Deliberately *not* `library()`: that returns every stored vector, which
    /// is the wrong payload for a list of names and counts (see
    /// ``PersonSummary``).
    public func people() async throws -> [PersonSummary] {
        try withContext { context in
            try context
                .fetch(
                    FetchDescriptor<Person>(
                        sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.name)]
                    )
                )
                .map(Self.summarize)
        }
    }

    /// One person's summary, or nil if the row is gone.
    public func person(id: UUID) async throws -> PersonSummary? {
        try withContext { context in
            try context.person(id: id).map(Self.summarize)
        }
    }

    /// Creates a person with no embeddings yet.
    ///
    /// Unlike ``upsertPerson(named:at:)``, an existing name is an **error**
    /// rather than a silent merge: "Add Person" in the UI is a promise to
    /// create one, and quietly returning someone else's profile is how two
    /// people's voices end up averaged together.
    ///
    /// - Throws: ``ProfileSourceError/invalidName`` or
    ///   ``ProfileSourceError/duplicateName(_:)``.
    @discardableResult
    public func createPerson(named name: String, at date: Date = Date()) async throws -> PersonSummary {
        try withContext { context in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProfileSourceError.invalidName }
            if let existing = try context.person(named: trimmed) {
                throw ProfileSourceError.duplicateName(existing.name)
            }
            let person = Person(name: trimmed, createdAt: date)
            context.insert(person)
            try context.save()
            return Self.summarize(person)
        }
    }

    /// Renames a person, keeping every embedding they have.
    ///
    /// Case- and whitespace-only edits to their *own* name are allowed (that is
    /// how "bob" becomes "Bob"); colliding with a *different* person is refused,
    /// because `ProfileLibrary` resolves names case-insensitively and two
    /// identically-named profiles would make matching results ambiguous.
    @discardableResult
    public func renamePerson(id: UUID, to newName: String) async throws -> PersonSummary {
        try withContext { context in
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProfileSourceError.invalidName }
            guard let person = try context.person(id: id) else {
                throw ProfileSourceError.personNotFound(id: id)
            }
            if let clash = try context.person(named: trimmed), clash.id != id {
                throw ProfileSourceError.duplicateName(clash.name)
            }
            person.name = trimmed
            try context.save()
            return Self.summarize(person)
        }
    }

    /// "Reset learned voice", addressed by row identity.
    ///
    /// The by-name form is the CLI's (and `ProfileLearningSource`'s) door; the
    /// UI holds a `PersonSummary` and must not round-trip through a name that a
    /// rename could have just changed.
    ///
    /// - Returns: How many `autolearn` embeddings were removed.
    @discardableResult
    public func resetLearnedVoice(forPersonWithID id: UUID) async throws -> Int {
        try withContext { context in
            guard let person = try context.person(id: id) else {
                throw ProfileSourceError.personNotFound(id: id)
            }
            let learned = person.embeddings.filter { $0.source == .autolearn }
            for embedding in learned { context.delete(embedding) }
            return learned.count
        }
    }

    /// Drops **every** embedding, whatever its source — the first half of
    /// "re-enroll" (spec §Voice profiles).
    ///
    /// The person, their name, their creation date, and their assignment to
    /// existing transcripts all survive; only the voice evidence is cleared, so
    /// the fresh read that follows is not averaged with the old one.
    /// `embeddingSequence` is *not* reset: it is a monotonic FIFO cursor, and
    /// rewinding it would let a new embedding sort before a surviving one.
    ///
    /// - Returns: How many embeddings were removed.
    @discardableResult
    public func removeAllEmbeddings(forPersonWithID id: UUID) async throws -> Int {
        try withContext { context in
            guard let person = try context.person(id: id) else {
                throw ProfileSourceError.personNotFound(id: id)
            }
            let existing = person.embeddings
            for embedding in existing { context.delete(embedding) }
            return existing.count
        }
    }

    /// Bulk fold-in addressed by row identity — the enrollment and clip-upload
    /// path, where the target person is already selected in the UI.
    @discardableResult
    public func foldIn(
        contentsOf vectors: [[Float]],
        intoPersonWithID id: UUID,
        source: EmbeddingSource,
        at date: Date = Date(),
        cap: Int = ProfileFoldPolicy.defaultCap
    ) async throws -> ProfileFoldOutcome {
        try withContext { context in
            guard let person = try context.person(id: id) else {
                throw ProfileSourceError.personNotFound(id: id)
            }
            var evicted = 0
            var stored = false
            for vector in vectors {
                if ProfileFoldPolicy.storableVector(vector) != nil { stored = true }
                evicted += Self.foldIn(
                    vector, into: person, source: source, at: date, cap: cap, in: context
                )
            }
            try context.save()
            return ProfileFoldOutcome(
                profileID: person.id,
                name: person.name,
                created: false,
                stored: stored,
                embeddingCount: person.embeddings.count,
                evictedCount: evicted
            )
        }
    }

    /// Row → `Sendable` summary. The one place the mapping lives.
    private static func summarize(_ person: Person) -> PersonSummary {
        var counts: [EmbeddingSource: Int] = [:]
        for embedding in person.embeddings {
            counts[embedding.source, default: 0] += 1
        }
        let slots = person.speakerSlots
        let recordings = Set(slots.compactMap { $0.recording?.id })
        return PersonSummary(
            id: person.id,
            name: person.name,
            createdAt: person.createdAt,
            embeddingCounts: counts,
            assignedSlotCount: slots.count,
            assignedRecordingCount: recordings.count
        )
    }

    // MARK: - Import / export

    /// Replaces the SwiftData library with a JSON one (the CLI's file).
    ///
    /// Used by the "import profiles" path and, in tests, to stage the same
    /// fixture into both backings so their behavior can be compared directly.
    public func replaceAll(with snapshot: ProfileLibrary) async throws {
        try withContext { context in
            for person in try context.fetch(FetchDescriptor<Person>()) {
                context.delete(person)
            }
            for profile in snapshot.profiles {
                let person = Person(id: profile.id, name: profile.name, createdAt: profile.createdAt)
                context.insert(person)
                for (offset, embedding) in profile.embeddings.enumerated() {
                    let row = PersonEmbedding(value: embedding, sequence: offset)
                    context.insert(row)
                    person.embeddings.append(row)
                }
                person.embeddingSequence = profile.embeddings.count
            }
        }
    }

    // MARK: - Implementation

    /// Runs `body` against a fresh context and saves once.
    ///
    /// Synchronous on purpose — see the type comment. `body` must not return a
    /// `PersistentModel`; the compiler cannot enforce that, so it is a rule of
    /// this file, and every call site here returns a value type.
    private func withContext<T>(_ body: (ModelContext) throws -> T) throws -> T {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let result = try body(context)
        if context.hasChanges { try context.save() }
        return result
    }

    private static func upsertPerson(
        named name: String,
        in context: ModelContext,
        now: Date
    ) throws -> (person: Person, created: Bool) {
        if let existing = try context.person(named: name) { return (existing, false) }
        let person = Person(name: name.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: now)
        context.insert(person)
        return (person, true)
    }

    /// The fold-in itself: `ProfileFoldPolicy`'s two rules, applied to rows.
    ///
    /// - Returns: How many embeddings were evicted at the cap.
    private static func foldIn(
        _ vector: [Float],
        into person: Person,
        source: EmbeddingSource,
        at date: Date,
        cap: Int,
        in context: ModelContext
    ) -> Int {
        guard let normalized = ProfileFoldPolicy.storableVector(vector) else { return 0 }

        person.embeddingSequence += 1
        let row = PersonEmbedding(
            vector: normalized,
            addedAt: date,
            source: source,
            sequence: person.embeddingSequence
        )
        context.insert(row)
        person.embeddings.append(row)

        // `context.delete` does not take the row out of `person.embeddings`
        // until the context is saved, and a bulk fold-in saves once at the end.
        // Counting the relationship array directly would therefore re-evict
        // rows already marked for deletion on the next vector — harmless for
        // the final state (deleting twice is a no-op) but it over-reports
        // `evictedCount`, which is a number the UI shows the user. `isDeleted`
        // is the live view.
        let live = person.orderedEmbeddings.filter { !$0.isDeleted }
        let overflow = ProfileFoldPolicy.evictionCount(currentCount: live.count, cap: cap)
        guard overflow > 0 else { return 0 }

        // Oldest-first by insertion order, matching the Phase-1 array
        // semantics exactly (dates tie on bulk folds; sequence never does).
        for victim in live.prefix(overflow) {
            context.delete(victim)
        }
        return overflow
    }
}

/// Failures specific to a profile source.
public enum ProfileSourceError: Error, Sendable, Equatable {
    case personNotFound(id: UUID)
    /// A name that is empty once trimmed. Phase 6.
    case invalidName
    /// Another person already answers to this name (case-insensitively).
    /// Carries the *existing* spelling, so the message can show it. Phase 6.
    case duplicateName(String)
}

extension ProfileSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .personNotFound(let id):
            return "No person with id \(id) in the profile library."
        case .invalidName:
            return "A person needs a name."
        case .duplicateName(let name):
            return "“\(name)” is already in your people list. Names have to be unique so "
                + "matched speakers are never ambiguous."
        }
    }
}
