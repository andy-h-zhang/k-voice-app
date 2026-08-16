import KVoiceCore
import SwiftUI

/// One speaker turn, shown as a `Speaker — [hh:mm:ss]` header above its
/// paragraphs,
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
                    onAssign: onAssign
                )
                .id(ParagraphAnchor(utteranceIndex: index))
            }
        }
    }

    /// The slots under this turn, resolved to speakers.
    private var turnSpeakers: [EditorSpeaker] {
        turn.speakerLabels.compactMap { model.speaker(labeled: $0) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if turnSpeakers.isEmpty {
                Text(turn.speakerName).font(.headline)
            } else {
                Menu {
                    if let only = turnSpeakers.count == 1 ? turnSpeakers[0] : nil {
                        SpeakerMenuItems(
                            speaker: only,
                            allSpeakers: speakers,
                            onAssign: onAssign,
                            onMerge: onMerge,
                            onClear: onClear
                        )
                    } else {
                        // Two diarized speakers sharing one name collapsed into
                        // this turn. Operating on "the" speaker would silently
                        // touch half its lines, so each slot is addressed by
                        // name — and merging them is the obvious repair.
                        Text("Diarization split this speaker")
                        ForEach(turnSpeakers) { speaker in
                            Menu("Speaker \(speaker.label) · \(speaker.utteranceCount) lines") {
                                SpeakerMenuItems(
                                    speaker: speaker,
                                    allSpeakers: speakers,
                                    onAssign: onAssign,
                                    onMerge: onMerge,
                                    onClear: onClear
                                )
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(turn.speakerName)
                            .font(.headline)
                            .foregroundStyle(
                                turnSpeakers.allSatisfy(\.isUnknown) ? Color.orange : Color.primary
                            )
                        if turn.spansMultipleSlots {
                            Image(systemName: "person.2.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(
                    turn.spansMultipleSlots
                        ? "Two diarized speakers (\(turn.speakerLabels.joined(separator: ", "))) "
                            + "share this name."
                        : "Speaker operations for this turn."
                )
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
    let onAssign: (SpeakerAssignmentRequest) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var utterance: EditorUtterance? { model.utterance(utteranceIndex) }

    /// This line's *own* slot, not its turn's.
    ///
    /// The two differ whenever two slots share a display name and Core grouped
    /// them into one turn; taking it from the turn would offer this paragraph a
    /// "reassign to X" where X is already its slot.
    private var speakerLabel: String { utterance?.speakerLabel ?? "" }

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
                    // Guarded so that restoring the field's text on the way out
                    // cannot re-arm the debounce that was just flushed.
                    guard isEditing else { return }
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
            // No `textSelection(.enabled)` here on purpose: it installs its own
            // gestures that contend with the two below, and selecting text is
            // what the editing field (one double-click away) is for.
            Text(model.text(forUtterance: utteranceIndex))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // `exclusively(before:)` rather than two `onTapGesture`s:
                // stacked tap modifiers apply outward, so the single-tap ends
                // up *outside* the double-tap and can claim the first click of
                // a double-click. This states the precedence outright — the
                // double-tap is tried first, and the single-tap only runs once
                // it has failed.
                .gesture(
                    TapGesture(count: 2)
                        .onEnded { beginEditing() }
                        .exclusively(
                            before: TapGesture(count: 1)
                                .onEnded { playback.seek(toUtterance: utteranceIndex) }
                        )
                )
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
        // Order matters: leaving edit mode *first* means the restore below
        // cannot re-arm the debounce this call just flushed.
        isEditing = false
        // Commit now rather than waiting out the debounce: the user has
        // finished with this paragraph.
        model.flushPendingEdits()
        // A paragraph cleared to nothing is not persisted (the model refuses
        // it, so the row cannot silently vanish from the transcript); restore
        // what is stored so the field and the database agree.
        draft = model.text(forUtterance: utteranceIndex)
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
