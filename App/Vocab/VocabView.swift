import KVoiceCore
import SwiftUI

/// The Vocab tab: the words the transcriber would otherwise guess at.
///
/// ## What this actually does
///
/// Every term here is sent with each transcription request as AssemblyAI's
/// `keyterms_prompt`, which biases the recognizer towards spelling them the way
/// you wrote them. That is the whole mechanism, and it is a **text** one.
///
/// There is no way to teach the recognizer a term by *recording* it: AssemblyAI
/// accepts no audio exemplars for custom vocabulary, and the on-device model
/// that does take clips is the speaker embedder, which — as `EnrollmentScript`
/// puts it — characterizes a voice, not a vocabulary. So this tab is a list of
/// words, and the clips live in People where they belong.
///
/// ## Why it is a tab and not a settings field
///
/// It was a text box in Settings, under a heading, competing with the API key
/// and the storage folder. But vocabulary is not something you configure once —
/// it grows every time a meeting invents a word, and the budget arithmetic
/// underneath it is something you want to *see* while you edit. Settings is for
/// things you set; this is a thing you keep.
struct VocabView: View {

    @Environment(AppServices.self) private var services

    @State private var draft: String = ""
    @FocusState private var draftFocused: Bool
    @State private var editing: String?
    @State private var editText: String = ""

    private var report: KeytermReport { services.appSettings.keytermReport }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if report.entered.isEmpty { emptyState } else { list }
            Divider()
            budgetBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vocab")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(
                    "Names, jargon and product words the transcriber would otherwise guess at. "
                        + "Sent with every transcription."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("Add a term…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($draftFocused)
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(report.entered, id: \.self) { term in
                    row(term)
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func row(_ term: String) -> some View {
        HStack(spacing: 8) {
            if editing == term {
                TextField("Term", text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitEdit(of: term) }
                    .onExitCommand { editing = nil }
            } else {
                Text(term)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                // Why a term is not being sent matters more than that it is:
                // the API drops both silently, and "my terms aren't working" is
                // the bug report that follows.
                if report.tooLong.contains(term) {
                    tag("too long", .orange)
                } else if !report.accepted.contains(term) {
                    tag(isDuplicate(term) ? "duplicate" : "past budget", .secondary)
                }

                Button {
                    editing = term
                    editText = term
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit this term")

                Button {
                    remove(term)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this term")
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func tag(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quinary, in: Capsule())
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Vocab Yet", systemImage: "character.book.closed")
        } description: {
            Text(
                "Add the words this transcriber keeps getting wrong — people's names, "
                    + "product names, acronyms. They are sent with every transcription so it "
                    + "spells them your way."
            )
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Budget

    private var budgetBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(report.accepted.count) term\(report.accepted.count == 1 ? "" : "s") sent")
                Text("·")
                Text("\(report.wordsUsed) / \(report.wordBudget) words")
                    .foregroundStyle(report.isOverBudget ? .orange : .secondary)
                    .monospacedDigit()
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let problems = report.problemSummary {
                Label(problems, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Editing

    /// The stored list is a newline-joined string, because that is the shape
    /// `SettingsStore.keyterms` and `KeytermReport` already agree on. This tab
    /// edits terms one at a time and writes the whole list back.
    private func setTerms(_ terms: [String]) {
        services.appSettings.keytermsText = terms.joined(separator: "\n")
        services.appSettings.commitKeyterms()
    }

    private func addDraft() {
        let term = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        setTerms(report.entered + [term])
        draft = ""
        // Focus stays in the field: adding vocabulary is something people do in
        // a run of five, not one at a time.
        draftFocused = true
    }

    private func remove(_ term: String) {
        setTerms(report.entered.filter { $0 != term })
    }

    private func commitEdit(of term: String) {
        let replacement = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        guard !replacement.isEmpty else { return remove(term) }
        setTerms(report.entered.map { $0 == term ? replacement : $0 })
    }

    /// Whether an earlier term already claimed this one's spelling.
    private func isDuplicate(_ term: String) -> Bool {
        guard let first = report.entered.firstIndex(where: { $0.lowercased() == term.lowercased() }),
            let this = report.entered.firstIndex(of: term)
        else { return false }
        return first != this
    }
}

#if DEBUG

#Preview("Vocab") {
    let fixture = PreviewFixture.make(.populated)
    VocabView()
        .environment(fixture.services)
        .frame(width: 700, height: 560)
}

#endif
