import KVoiceCore
import SwiftUI

/// One speaker turn: the `Speaker — [hh:mm:ss]` header the exports also use,
/// and its paragraphs.
struct TurnView: View {

    let turn: EditorTurn
    let model: TranscriptEditorModel
    let playback: TranscriptPlayback
    let speakers: [EditorSpeaker]
    let onAssign: (SpeakerAssignmentRequest) -> Void
    let onMerge: (SpeakerMergeRequest) -> Void
    let onClear: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ForEach(turn.utteranceIndices, id: \.self) { index in
                ParagraphView(
                    utteranceIndex: index,
                    model: model,
                    playback: playback,
                    speakers: speakers,
                    speakerLabel: turn.speakerLabel,
                    onAssign: onAssign
                )
                .id(index)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let speaker = model.speaker(labeled: turn.speakerLabel) {
                Menu {
                    SpeakerMenuItems(
                        speaker: speaker,
                        allSpeakers: speakers,
                        onAssign: onAssign,
                        onMerge: onMerge,
                        onClear: onClear
                    )
                } label: {
                    Text(turn.speakerName)
                        .font(.headline)
                        .foregroundStyle(speaker.isUnknown ? Color.orange : Color.primary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text(turn.speakerName).font(.headline)
            }

            Button {
                playback.seek(to: Double(turn.startMs) / 1_000)
            } label: {
                Text(TimestampFormatter.bracketedClockTime(milliseconds: turn.startMs))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Jump to this turn.")

            Spacer(minLength: 0)
        }
    }
}

/// One utterance: a timestamp that seeks, the text, and the inline editor.
///
/// The paragraph is a `Text` until it is being edited, and only then a text
/// field. That is what makes single-click-to-seek possible (spec: "click a
/// segment to jump audio") without fighting a caret, and it keeps a
/// 700-paragraph meeting from instantiating 700 live text views.
struct ParagraphView: View {

    let utteranceIndex: Int
    let model: TranscriptEditorModel
    let playback: TranscriptPlayback
    let speakers: [EditorSpeaker]
    /// The slot this paragraph's turn belongs to — excluded from the
    /// "reassign this line to…" list, since it is already there.
    let speakerLabel: String
    let onAssign: (SpeakerAssignmentRequest) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var utterance: EditorUtterance? { model.utterance(utteranceIndex) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            timestamp
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(HighlightBackground(utteranceIndex: utteranceIndex, playback: playback))
        .contextMenu { menu }
    }

    // MARK: - Pieces

    private var timestamp: some View {
        Button {
            playback.seek(toUtterance: utteranceIndex)
        } label: {
            Text(TimestampFormatter.clockTime(milliseconds: utterance?.startMs ?? 0))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Jump to this line.")
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            TextField("Transcript text", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...)
                .focused($isFocused)
                .onChange(of: draft) { _, new in
                    model.setText(new, forUtterance: utteranceIndex)
                }
                .onChange(of: isFocused) { _, focused in
                    // Clicking away commits, like every other inline edit in
                    // this app (the library's rename does the same).
                    if !focused { endEditing() }
                }
                .onExitCommand { endEditing() }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(model.text(forUtterance: utteranceIndex))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // The 2-tap gesture is declared first so it wins the race;
                // a single click still falls through to seek.
                .onTapGesture(count: 2) { beginEditing() }
                .onTapGesture { playback.seek(toUtterance: utteranceIndex) }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Edit Text") { beginEditing() }
        Button("Play from Here") { playback.playFrom(utterance: utteranceIndex) }

        Divider()

        let others = speakers.filter { $0.label != speakerLabel }
        if !others.isEmpty {
            Menu("Reassign This Line To") {
                ForEach(others) { speaker in
                    Button(speaker.displayName) {
                        model.reassignUtterance(utteranceIndex, toSpeakerLabeled: speaker.label)
                    }
                }
            }
        }
        Button("Reassign This Line to a Person…") {
            onAssign(.utterance(index: utteranceIndex))
        }
    }

    // MARK: - Editing

    private func beginEditing() {
        draft = model.text(forUtterance: utteranceIndex)
        isEditing = true
        // Deferred by one turn of the run loop on purpose: the text field does
        // not exist until the `isEditing` change has been rendered, and
        // focusing a field that is not in the hierarchy yet silently does
        // nothing — the symptom being a double-click that shows a field but
        // leaves the caret elsewhere.
        Task { @MainActor in isFocused = true }
    }

    /// Leaves the field. There is no "cancel": this is a debounced autosave
    /// editor, so what was typed is already on its way to the row, and Escape
    /// means "I am done here" rather than "undo that".
    private func endEditing() {
        // Commit now rather than waiting out the debounce: the user has
        // finished with this paragraph.
        model.flushPendingEdits()
        // A paragraph cleared to nothing is not persisted (the model refuses
        // it, so the row cannot silently vanish from the transcript); restore
        // what is stored so the field and the database agree.
        draft = model.text(forUtterance: utteranceIndex)
        isEditing = false
    }
}

/// The playback highlight, as a background view of its own.
///
/// Deliberately a separate view: it is the only thing that reads
/// ``TranscriptPlayback/currentUtteranceIndex``, so when the highlight moves
/// SwiftUI re-evaluates these few-pixel backgrounds and *not* the paragraphs'
/// text. In a 700-paragraph meeting that is the difference between re-rendering
/// the document every turn and re-rendering nothing.
struct HighlightBackground: View {

    let utteranceIndex: Int
    let playback: TranscriptPlayback

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(playback.currentUtteranceIndex == utteranceIndex
                ? Color.accentColor.opacity(0.16)
                : Color.clear)
    }
}
