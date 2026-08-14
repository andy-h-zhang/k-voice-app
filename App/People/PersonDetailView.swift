import KVoiceCore
import SwiftUI

/// One person's voice profile: what KVoice knows about their voice, where it
/// learned it, and every per-profile action from spec §Voice profiles.
struct PersonDetailView: View {

    @Environment(AppServices.self) private var services

    let person: PersonSummary

    let onEnroll: () -> Void
    let onAddClips: () -> Void
    let onReEnroll: () -> Void
    let onResetLearned: () -> Void
    let onDelete: () -> Void

    /// The name being edited. Seeded from `person` and reset whenever the
    /// selection changes (`PeopleView` gives this view an `.id`), so it can
    /// never commit one person's text to another's row.
    @State private var draftName: String = ""

    private var model: PeopleModel { services.people }

    private var trimmedDraft: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRenamed: Bool {
        !trimmedDraft.isEmpty && trimmedDraft != person.name
    }

    private var renameConflict: Bool {
        isRenamed && !model.isNameAvailable(trimmedDraft, excluding: person.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()

                if person.hasVoice {
                    voiceSummary
                } else {
                    noVoiceYet
                }

                if person.assignedRecordingCount > 0 {
                    appearances
                }

                Divider()
                actions
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            draftName = person.name
            // This view is `.id`-ed per person, so appearing means the
            // selection moved — and "Removed 4 learned samples" is about
            // whoever was on screen before.
            services.people.lastActionMessage = nil
        }
        .onChange(of: person.name) { _, newValue in draftName = newValue }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .onSubmit(commitRename)

                if isRenamed {
                    Button("Rename", action: commitRename)
                        .disabled(renameConflict)
                    Button("Revert") { draftName = person.name }
                        .buttonStyle(.borderless)
                }
            }

            if renameConflict {
                Label(
                    "Another person is already called “\(trimmedDraft)”.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            Text("Added \(Display.rowDate(person.createdAt))")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let message = model.lastActionMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
    }

    private func commitRename() {
        guard isRenamed, !renameConflict else { return }
        let name = trimmedDraft
        Task { await services.people.rename(id: person.id, to: name) }
    }

    // MARK: - Voice

    private var voiceSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Voice samples")
                    .font(.headline)
                Spacer()
                Text("\(person.embeddingCount) of \(SpeakerProfile.defaultEmbeddingCap) stored")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 10) {
                ForEach(EmbeddingSource.allCases, id: \.self) { source in
                    SourceChip(source: source, count: person.embeddingCount(source: source))
                }
            }

            Text(capExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var capExplanation: String {
        if person.embeddingCount >= SpeakerProfile.defaultEmbeddingCap {
            return """
                This profile is full, so each new sample replaces the oldest one — real \
                meeting audio gradually takes over from the original read, which is what \
                makes recognition improve with use.
                """
        }
        return """
            KVoice keeps up to \(SpeakerProfile.defaultEmbeddingCap) samples per person and \
            drops the oldest past that, so recent audio counts for more.
            """
    }

    /// The empty state that matters most: a name with no voice is a profile
    /// that can never match anything, and nothing else on screen would say so.
    private var noVoiceYet: some View {
        NoticeBanner(
            icon: "waveform.badge.exclamationmark",
            tint: .orange,
            title: "No voice recorded yet",
            message: """
                \(person.name) is just a name until KVoice has heard them. Record a \
                30-second read, or add clips of them speaking — either one is enough to \
                start matching them in transcripts.
                """
        ) {
            HStack(spacing: 8) {
                Button("Record a Voice…", action: onEnroll)
                    .buttonStyle(.borderedProminent)
                Button("Add Audio Files…", action: onAddClips)
            }
        }
    }

    // MARK: - Appearances

    private var appearances: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("In your library")
                .font(.headline)
            Text(
                """
                Named as a speaker in \(person.assignedRecordingCount) \
                recording\(person.assignedRecordingCount == 1 ? "" : "s") \
                (\(person.assignedSlotCount) speaker\(person.assignedSlotCount == 1 ? "" : "s") \
                in total).
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    onEnroll()
                } label: {
                    Label(person.hasVoice ? "Record More" : "Record a Voice…", systemImage: "mic")
                }

                Button {
                    onAddClips()
                } label: {
                    Label("Add Audio Files…", systemImage: "waveform.badge.plus")
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Button("Re-enroll…", action: onReEnroll)
                    .disabled(!person.hasVoice)
                    .help("Clear every stored sample and record a fresh 30-second read")

                Button("Reset Learned Voice", action: onResetLearned)
                    .disabled(person.learnedEmbeddingCount == 0)
                    .help("Remove only what KVoice picked up from recordings")

                Spacer()

                Button("Delete…", role: .destructive, action: onDelete)
            }

            Text(resetExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resetExplanation: String {
        person.learnedEmbeddingCount == 0
            ? """
                “Reset learned voice” becomes available once KVoice has learned from a \
                recording you labelled — it removes just those samples and keeps the ones \
                you supplied.
                """
            : """
                “Reset learned voice” removes the \(person.learnedEmbeddingCount) \
                auto-learned sample\(person.learnedEmbeddingCount == 1 ? "" : "s") and keeps \
                the \(person.suppliedEmbeddingCount) you supplied. “Re-enroll” removes \
                everything and starts over.
                """
    }
}

// MARK: - Source chip

private struct SourceChip: View {

    let source: EmbeddingSource
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)")
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(count == 0 ? .secondary : .primary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .help(explanation)
    }

    private var title: String {
        switch source {
        case .enrollment: return "Enrolled"
        case .upload: return "Uploaded"
        case .autolearn: return "Auto-learned"
        }
    }

    private var explanation: String {
        switch source {
        case .enrollment: return "Captured by reading the on-screen script"
        case .upload: return "Taken from audio files you added"
        case .autolearn: return "Learned from recordings where you named this speaker"
        }
    }
}
