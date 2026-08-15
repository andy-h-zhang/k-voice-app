import KVoiceCore
import SwiftUI

/// What an enrollment sheet was opened to do.
///
/// `Identifiable` so it can drive `.sheet(item:)`, which — unlike a boolean
/// plus a separate payload — cannot present a sheet whose subject has already
/// changed underneath it.
struct EnrollmentRequest: Identifiable {
    let id = UUID()
    let target: EnrollmentModel.Target
    let mode: EnrollmentModel.Mode

    static func guided(for person: PersonSummary?) -> EnrollmentRequest {
        EnrollmentRequest(target: target(for: person), mode: .guided)
    }

    static func clips(for person: PersonSummary?) -> EnrollmentRequest {
        EnrollmentRequest(target: target(for: person), mode: .clips([]))
    }

    private static func target(for person: PersonSummary?) -> EnrollmentModel.Target {
        guard let person else { return .newPerson }
        return .existing(id: person.id, name: person.name)
    }
}

/// The People section: the voice profiles that turn "Speaker A" into a name.
///
/// A list-plus-detail split *inside* the detail column rather than a third
/// `NavigationSplitView` column, so this section's shape is its own business
/// and the window's two-column layout stays as Phase 4 left it.
struct PeopleView: View {

    @Environment(AppServices.self) private var services

    @State private var enrollment: EnrollmentRequest?
    @State private var confirmingDelete: PersonSummary?
    @State private var confirmingReEnroll: PersonSummary?
    @State private var confirmingReset: PersonSummary?
    @State private var isAddingPerson = false
    @State private var newPersonName = ""

    private var model: PeopleModel { services.people }

    var body: some View {
        splitOrEmptyState
            .navigationTitle("People")
            .toolbar { addPersonToolbarItem }
            .task { await model.reload() }
            .sheet(item: $enrollment) { request in
                EnrollmentView(request: request) { result in
                    Task { await services.people.refreshAfterEnrollment(personID: result.personID) }
                }
                .environment(services)
            }
            .modifier(NewPersonPrompt(isPresented: $isAddingPerson, name: $newPersonName))
            .modifier(PeopleErrorAlert())
            .modifier(DeleteConfirmation(person: $confirmingDelete))
            .modifier(ReEnrollConfirmation(person: $confirmingReEnroll, onClearedVoice: { person in
                enrollment = .guided(for: person)
            }))
            .modifier(ResetLearnedConfirmation(person: $confirmingReset))
    }

    // MARK: - Body pieces

    @ViewBuilder
    private var splitOrEmptyState: some View {
        @Bindable var model = services.people

        if !model.hasLoaded {
            // Nothing, rather than the empty state: the first read is a
            // millisecond, and flashing "no people yet" at someone who has
            // twenty is worse than a beat of blankness.
            Color.clear
        } else if model.isEmpty {
            PeopleEmptyState(
                onEnroll: { enrollment = .guided(for: nil) },
                onImport: { enrollment = .clips(for: nil) }
            )
        } else {
            // An `HStack` and a `Divider`, not an `HSplitView`.
            //
            // `HSplitView` gives each pane the width that pane asks for and
            // then lets the total run past its own bounds — so the person
            // detail, whose ideal width is its 640-point reading column, was
            // drawn half outside the window with its Delete button off the
            // right edge. It has no way to say "share what is actually here".
            //
            // A fixed list column and a detail that takes the rest cannot
            // overflow, and it is the shape Mail and Notes use for the same
            // job. The width the user drags is still there — it is the window's
            // own sidebar divider, one level out.
            HStack(spacing: 0) {
                list(selection: $model.selection)
                    .frame(width: 200)

                Divider()

                detail
                    // `idealWidth` for the same reason as `RootView`'s: this
                    // column's content is paragraphs and a 640-point reading
                    // frame, and an unclamped ideal propagates out to the
                    // window's split view and squeezes the sidebar away.
                    .frame(
                        idealWidth: 360,
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var addPersonToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Record a Voice…") { enrollment = .guided(for: nil) }
                Button("Add from Audio Files…") { enrollment = .clips(for: nil) }
                Divider()
                Button("Add Name Only…") {
                    newPersonName = ""
                    isAddingPerson = true
                }
            } label: {
                Label("Add Person", systemImage: "person.badge.plus")
            } primaryAction: {
                enrollment = .guided(for: nil)
            }
            .help("Create a voice profile so KVoice can name this person in transcripts")
        }
    }

    // MARK: - List

    private func list(selection: Binding<UUID?>) -> some View {
        List(model.people, selection: selection) { person in
            PersonRow(person: person)
                .tag(person.id)
                .contextMenu {
                    Button("Record a Voice…") { enrollment = .guided(for: person) }
                    Button("Add from Audio Files…") { enrollment = .clips(for: person) }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmingDelete = person }
                }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let person = model.selected {
            PersonDetailView(
                person: person,
                onEnroll: { enrollment = .guided(for: person) },
                onAddClips: { enrollment = .clips(for: person) },
                onReEnroll: { confirmingReEnroll = person },
                onResetLearned: { confirmingReset = person },
                onDelete: { confirmingDelete = person }
            )
            .id(person.id)
        } else {
            ContentUnavailableView(
                "No one selected",
                systemImage: "person.crop.circle",
                description: Text("Pick someone to see their voice profile.")
            )
        }
    }

}

// MARK: - Prompts
//
// Each dialog is its own `ViewModifier` rather than another `.alert` chained
// onto the body. Five of them inline made the whole view expression too big for
// the type-checker to solve — and separately, one dialog per type is easier to
// read than a 90-line modifier chain.

/// "Add Name Only…" — creates a person with no voice yet, which is a legitimate
/// thing to want (add the team now, enroll them as they turn up).
private struct NewPersonPrompt: ViewModifier {

    @Environment(AppServices.self) private var services

    @Binding var isPresented: Bool
    @Binding var name: String

    func body(content: Content) -> some View {
        content.alert("New person", isPresented: $isPresented) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let value = name
                Task { await services.people.createPerson(named: value) }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(
                """
                Creates the name now; record or import their voice afterwards. \
                KVoice can't recognize anyone until it has heard them.
                """
            )
        }
    }
}

private struct PeopleErrorAlert: ViewModifier {

    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content.alert(
            "People",
            isPresented: Binding(
                get: { services.people.errorMessage != nil },
                set: { if !$0 { services.people.errorMessage = nil } }
            ),
            presenting: services.people.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

/// Delete confirmation. Its message is the whole reason ``PersonSummary``
/// carries assignment counts: a user deleting someone deserves to know what
/// happens to the transcripts that already name them.
private struct DeleteConfirmation: ViewModifier {

    @Environment(AppServices.self) private var services

    @Binding var person: PersonSummary?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            person.map { "Delete “\($0.name)”?" } ?? "Delete this person?",
            isPresented: Binding(
                get: { person != nil },
                set: { if !$0 { person = nil } }
            ),
            titleVisibility: .visible,
            presenting: person
        ) { target in
            Button("Delete", role: .destructive) {
                Task { await services.people.delete(id: target.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(Self.impact(of: target))
        }
    }

    static func impact(of person: PersonSummary) -> String {
        var parts = [
            "Their \(person.embeddingCount) stored voice sample"
                + (person.embeddingCount == 1 ? "" : "s")
                + " will be removed, and KVoice will stop recognizing them."
        ]
        if person.assignedRecordingCount > 0 {
            parts.append(
                """
                \(person.assignedRecordingCount) recording\
                \(person.assignedRecordingCount == 1 ? "" : "s") already name them; those \
                transcripts are kept, but the speaker goes back to its diarized label \
                (“Speaker A”) and can be named again.
                """
            )
        }
        parts.append("This can't be undone.")
        return parts.joined(separator: " ")
    }
}

/// Re-enroll: clear every sample, *then* record a fresh read. Two steps, one
/// confirmation, because the destructive half is the half worth confirming.
private struct ReEnrollConfirmation: ViewModifier {

    @Environment(AppServices.self) private var services

    @Binding var person: PersonSummary?
    let onClearedVoice: (PersonSummary) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            person.map { "Re-enroll “\($0.name)”?" } ?? "Re-enroll?",
            isPresented: Binding(
                get: { person != nil },
                set: { if !$0 { person = nil } }
            ),
            titleVisibility: .visible,
            presenting: person
        ) { target in
            Button("Clear and Record Again", role: .destructive) {
                Task {
                    if await services.people.clearVoice(id: target.id) {
                        onClearedVoice(target)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(
                """
                This removes all \(target.embeddingCount) stored voice sample\
                \(target.embeddingCount == 1 ? "" : "s") — including anything auto-learned — \
                and then records a fresh 30-second read. Transcripts already naming \
                \(target.name) are not changed.
                """
            )
        }
    }
}

private struct ResetLearnedConfirmation: ViewModifier {

    @Environment(AppServices.self) private var services

    @Binding var person: PersonSummary?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            person.map { "Reset the learned voice for “\($0.name)”?" } ?? "Reset learned voice?",
            isPresented: Binding(
                get: { person != nil },
                set: { if !$0 { person = nil } }
            ),
            titleVisibility: .visible,
            presenting: person
        ) { target in
            Button("Reset Learned Voice", role: .destructive) {
                Task { await services.people.resetLearnedVoice(id: target.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(
                """
                Drops the \(target.learnedEmbeddingCount) sample\
                \(target.learnedEmbeddingCount == 1 ? "" : "s") KVoice picked up from your \
                recordings, and keeps the \(target.suppliedEmbeddingCount) you supplied \
                yourself. Use this if a mislabelled speaker taught it the wrong voice.
                """
            )
        }
    }
}

// MARK: - Row

private struct PersonRow: View {

    let person: PersonSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: person.hasVoice ? "person.crop.circle.fill" : "person.crop.circle.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(person.hasVoice ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        guard person.hasVoice else { return "No voice yet" }
        let count = person.embeddingCount
        return "\(count) voice sample\(count == 1 ? "" : "s")"
    }
}

// MARK: - Empty state

/// The first thing anyone sees in this section, so it has to teach the model
/// the whole feature runs on: KVoice matches voices it has *heard before*, and
/// there are two ways to make that happen.
struct PeopleEmptyState: View {

    let onEnroll: () -> Void
    let onImport: () -> Void

    // The two cards, either side by side or stacked. `ViewThatFits` picks the
    // first arrangement that fits the width it is given, which in this window
    // is often under 500 points — where two columns leave each card narrow
    // enough to truncate its own buttons.
    private var cards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                enrollCard(sideBySide: true)
                autoLearnCard(sideBySide: true)
            }
            VStack(spacing: 16) {
                enrollCard(sideBySide: false)
                autoLearnCard(sideBySide: false)
            }
        }
        .frame(maxWidth: 720)
    }

    private func enrollCard(sideBySide: Bool) -> some View {
        ExplainerCard(
            sideBySide: sideBySide,
            icon: "mic.badge.plus",
            title: "Enroll a voice",
            message: """
                They read half a minute of text on screen, or you add clips of them \
                talking. Best when you know who will be in the meeting.
                """,
            actionTitle: "Record a Voice…",
            action: onEnroll,
            secondaryTitle: "Add Audio Files…",
            secondaryAction: onImport
        )
    }

    private func autoLearnCard(sideBySide: Bool) -> some View {
        ExplainerCard(
            sideBySide: sideBySide,
            icon: "wand.and.sparkles",
            title: "Or let it auto-learn",
            message: """
                Name an unknown speaker in a transcript and KVoice remembers that \
                voice — the profile is created for you, and gets better with every \
                recording. Enrolling just skips the first miss.
                """,
            actionTitle: nil,
            action: nil,
            secondaryTitle: nil,
            secondaryAction: nil
        )
    }

    // A `ScrollView` rather than a centred `VStack`, for two reasons that both
    // showed up on a real window. It stops the cards being stretched to the
    // window's full height — inside a fixed-height parent the `Spacer` that
    // bottom-aligns each card's buttons has nothing to push against, so a
    // 1200-point window produced 1200-point cards — and it means a window
    // resized short scrolls this text instead of clipping it.
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "person.2.badge.gearshape")
                    .font(.system(size: 46))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 8) {
                    Text("No people yet")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(
                        """
                        Transcription hands back “Speaker A” and “Speaker B”. KVoice turns those \
                        into names by comparing each voice against the profiles here — so until \
                        someone is in this list, every speaker stays anonymous.
                        """
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                }

                cards
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExplainerCard: View {

    /// Whether this card is sharing a row with the other one.
    let sideBySide: Bool
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Only when the cards are beside each other. Their paragraphs are
            // different lengths, so a spacer and a floor height are what line
            // the two button rows up and give the pair one silhouette. Stacked,
            // the same two things just leave a card with a hole in it.
            if sideBySide {
                Spacer(minLength: 0)
            }

            if let actionTitle, let action {
                // Two buttons side by side need about 300 points, and a card in
                // a narrow window gets rather less — at which point macOS
                // truncates the titles to "Record a…" rather than wrapping.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Button(actionTitle, action: action)
                            .buttonStyle(.borderedProminent)
                        if let secondaryTitle, let secondaryAction {
                            Button(secondaryTitle, action: secondaryAction)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button(actionTitle, action: action)
                            .buttonStyle(.borderedProminent)
                        if let secondaryTitle, let secondaryAction {
                            Button(secondaryTitle, action: secondaryAction)
                        }
                    }
                }
            }
        }
        .padding(16)
        // `idealWidth` is what makes the `ViewThatFits` above choose sensibly.
        // Without it a card's ideal width is its longest paragraph set on one
        // line — over a thousand points — so the side-by-side arrangement would
        // never be judged to fit and the cards would always stack, however wide
        // the window.
        .frame(
            idealWidth: 260,
            maxWidth: .infinity,
            minHeight: sideBySide ? 190 : nil,
            alignment: .leading
        )
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }
}
