import Foundation
import KVoiceCore
import Observation
import SwiftData

/// The People section's state and every mutation it offers (spec §Voice
/// profiles: "Per-profile actions: rename, re-enroll, delete, reset learned
/// voice").
///
/// ## Why this holds no `ModelContext`
///
/// `LibraryModel` opens its own contexts because `Recording` rows have no other
/// owner. `Person` rows do: ``SwiftDataProfileSource`` is the actor the whole
/// app already folds auto-learned embeddings through, and the rules about what
/// a rename may collide with, what "re-enroll" clears, and what "reset" keeps
/// live there with tests around them. This model is the observable face of that
/// actor — it holds `Sendable` ``PersonSummary`` values and nothing else.
@MainActor
@Observable
final class PeopleModel {

    // MARK: - Observable state

    private(set) var people: [PersonSummary] = []

    /// Selected row in the People list.
    var selection: UUID?

    /// Surfaced as an alert.
    var errorMessage: String?

    /// True while the first load is in flight, so the list can say "Loading"
    /// rather than flashing the "no people yet" empty state at every launch.
    private(set) var hasLoaded = false

    /// Set after a destructive action so the detail view can confirm quietly
    /// ("Removed 4 learned samples") instead of with a modal.
    var lastActionMessage: String?

    // MARK: - Dependencies

    let profiles: SwiftDataProfileSource
    let speakerModels: SpeakerModels
    let speakerModelState: SpeakerModelState
    let settings: SettingsStore

    /// Called after any change that alters what the *library* list shows —
    /// participant names come from `Person` rows, so a rename or delete makes
    /// those rows stale.
    @ObservationIgnored
    var onProfilesChanged: (() -> Void)?

    init(
        profiles: SwiftDataProfileSource,
        speakerModels: SpeakerModels,
        speakerModelState: SpeakerModelState,
        settings: SettingsStore
    ) {
        self.profiles = profiles
        self.speakerModels = speakerModels
        self.speakerModelState = speakerModelState
        self.settings = settings
    }

    // MARK: - Derived

    var selected: PersonSummary? {
        guard let selection else { return nil }
        return people.first { $0.id == selection }
    }

    var isEmpty: Bool { hasLoaded && people.isEmpty }

    /// Whether a name is free, judged against what is already on screen.
    ///
    /// A convenience for inline validation only — the authoritative check is
    /// `SwiftDataProfileSource.createPerson`, which throws on a collision. This
    /// exists so a user is told before reading thirty seconds of script, not
    /// after.
    func isNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        return !people.contains { $0.id != id && $0.name.lowercased() == key }
    }

    // MARK: - Reading

    func reload() async {
        do {
            people = try await profiles.people()
            hasLoaded = true
            // A selected person who has just been deleted must not leave the
            // detail pane showing a ghost.
            if let selection, !people.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        } catch {
            errorMessage = "Could not read your people list: \(Self.describe(error))"
            hasLoaded = true
        }
    }

    // MARK: - Mutations

    /// Creates an empty person. Enrollment fills their voice in afterwards.
    @discardableResult
    func createPerson(named name: String) async -> PersonSummary? {
        do {
            let summary = try await profiles.createPerson(named: name)
            await reload()
            selection = summary.id
            onProfilesChanged?()
            return summary
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    func rename(id: UUID, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard people.first(where: { $0.id == id })?.name != trimmed else { return }

        do {
            try await profiles.renamePerson(id: id, to: trimmed)
            await reload()
            onProfilesChanged?()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Deletes a person. Their embeddings go with them; the transcripts that
    /// named them survive with the speaker reverted to its diarized label.
    func delete(id: UUID) async {
        do {
            try await profiles.deletePerson(id: id)
            if selection == id { selection = nil }
            await reload()
            onProfilesChanged?()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// "Reset learned voice" — drops `autolearn` embeddings only.
    func resetLearnedVoice(id: UUID) async {
        do {
            let removed = try await profiles.resetLearnedVoice(forPersonWithID: id)
            await reload()
            lastActionMessage = removed == 0
                ? "There was nothing auto-learned to remove."
                : "Removed \(removed) auto-learned voice sample\(removed == 1 ? "" : "s")."
            onProfilesChanged?()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// The first half of "re-enroll": clear every embedding so the fresh read
    /// is not averaged with the old one. The caller then opens enrollment.
    @discardableResult
    func clearVoice(id: UUID) async -> Bool {
        do {
            try await profiles.removeAllEmbeddings(forPersonWithID: id)
            await reload()
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    /// Re-reads one person after an enrollment wrote to them.
    func refreshAfterEnrollment(personID: UUID) async {
        await reload()
        selection = personID
        onProfilesChanged?()
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
