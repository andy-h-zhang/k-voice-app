import KVoiceCore
import SwiftUI

/// What the assignment sheet was opened for.
enum SpeakerAssignmentRequest: Identifiable, Equatable {
    /// A whole diarized speaker — naming an unknown one, or correcting a match.
    /// This one auto-learns.
    case speaker(label: String)
    /// A single line. This one does not auto-learn; see
    /// ``TranscriptEditorModel/reassignUtterance(_:toSpeakerLabeled:)``.
    case utterance(index: Int)

    var id: String {
        switch self {
        case .speaker(let label): return "speaker:\(label)"
        case .utterance(let index): return "utterance:\(index)"
        }
    }
}

/// Which speaker is being folded into which. The source is the one that
/// disappears.
struct SpeakerMergeRequest: Identifiable, Equatable {
    let sourceLabel: String
    let destinationLabel: String

    var id: String { "\(sourceLabel)->\(destinationLabel)" }
}

/// Picks an existing person or creates one, for every "who is this?" the editor
/// asks (spec §Library and editor, plan §2 Phase 5: "'create new person'
/// inline").
///
/// One field does both jobs: typing filters the profile list *and* is the name
/// a new person gets. That keeps "Bob is already enrolled" and "Bob is new" on
/// the same path, and the exact-match check means typing an existing name picks
/// that profile rather than minting a duplicate — the same case-insensitive
/// identity rule the matcher uses.
struct SpeakerAssignmentSheet: View {

    let request: SpeakerAssignmentRequest
    let people: [PersonOption]
    /// False while the profile library is still being read.
    let arePeopleLoaded: Bool
    /// An explanatory line: the near-miss profile, or what is being moved.
    let context: String?
    let onAssign: (PersonChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let context {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Name", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(commit)

            list

            if case .utterance = request {
                Label(
                    "Moving one line does not train the voice profile — only "
                        + "reassigning a whole speaker does.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    // Also blocked until the profiles are in: assigning against
                    // an unread library would label an existing person as a new
                    // one. (`upsertPerson` would still resolve it correctly —
                    // this is about not telling the user something false.)
                    .disabled(choice == nil || !arePeopleLoaded)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { fieldFocused = true }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !arePeopleLoaded {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading voice profiles…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if matches.isEmpty {
                    Text(people.isEmpty ? "No voice profiles yet." : "No profile matches that name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(matches) { person in
                    Button {
                        query = person.name
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                            Text(person.name)
                            Spacer()
                            Text(
                                "\(person.embeddingCount) sample"
                                    + (person.embeddingCount == 1 ? "" : "s")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                    .background(
                        isExactMatch(person)
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
            }
        }
        .frame(height: 160)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Text

    private var title: String {
        switch request {
        case .speaker: return "Who is this speaker?"
        case .utterance: return "Who said this line?"
        }
    }

    private var confirmTitle: String {
        guard let choice else { return "Assign" }
        switch choice {
        case .existing(_, let name): return "Assign to \(name)"
        case .new(let name): return "Create “\(name)”"
        }
    }

    // MARK: - Selection

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matches: [PersonOption] {
        guard !trimmedQuery.isEmpty else { return people }
        return people.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    private func isExactMatch(_ person: PersonOption) -> Bool {
        person.name.localizedCaseInsensitiveCompare(trimmedQuery) == .orderedSame
    }

    /// The person the sheet would assign: an existing profile when the typed
    /// name matches one exactly, otherwise a new profile under that name.
    private var choice: PersonChoice? {
        guard !trimmedQuery.isEmpty else { return nil }
        if let exact = people.first(where: isExactMatch) {
            return .existing(id: exact.id, name: exact.name)
        }
        return .new(name: trimmedQuery)
    }

    private func commit() {
        guard let choice else { return }
        onAssign(choice)
        dismiss()
    }
}
