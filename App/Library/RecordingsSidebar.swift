import KVoiceCore
import SwiftUI

/// The left column: every recording, newest first, and a footer that says what
/// the app is doing and where the files are.
///
/// This replaces the old Recordings *section*, which was a full-width list you
/// had to navigate to before you could navigate again to a recording. The list
/// is the app's only accumulating content, so it lives in the position that
/// suits accumulating content — permanently on the left, one click from open.
///
/// ## Width discipline
///
/// This column is 200–420 points wide and it is the thing that must not
/// disappear. Everything in here therefore stays on one line: `.lineLimit(1)`
/// with truncation, and **never** `.fixedSize(horizontal: false, vertical: true)`
/// — a paragraph that reports its full single-line width from inside a column
/// this narrow is exactly what makes rows unreadable. Text that needs room lives
/// in the detail column, which has some.
struct RecordingsSidebar: View {

    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    @State private var editingID: UUID?
    @State private var draftTitle = ""
    @State private var pendingDelete: LibraryRow?

    private var library: LibraryModel { services.library }

    var body: some View {
        @Bindable var navigation = services.navigation

        VStack(spacing: 0) {
            if library.rows.isEmpty {
                emptyState
            } else {
                List(selection: $navigation.selectedRecording) {
                    ForEach(library.rows) { row in
                        RecordingSidebarRow(
                            row: row,
                            editingID: $editingID,
                            draftTitle: $draftTitle,
                            onRequestDelete: { pendingDelete = $0 }
                        )
                        .tag(row.id)
                    }
                }
                .listStyle(.sidebar)
                // On a custom theme the list's own material would sit as a
                // gray slab over the gradient; hidden, the themed background
                // below shows through. On System, untouched.
                .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            }

            Divider()
            footer
        }
        // Dimmed a step past the detail column's background, so the two panes
        // still read as two panes without the system material's help.
        .background { ThemeBackground(dimmed: true) }
        .onAppear { library.reload() }
        .confirmationDialog(
            "Move “\(pendingDelete?.title ?? "")” to the Trash?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { row in
            Button("Move to Trash", role: .destructive) {
                services.transcription.stopObserving(row.id)
                services.jobStatus.forget(row.id)
                // Before the delete, not after: the body must never spend a
                // frame pointed at a row that is already gone.
                services.navigation.recordingWasRemoved(row.id)
                services.library.moveToTrash(id: row.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The audio, the transcript, and any exports move to the Trash together.")
        }
    }

    // MARK: - Empty state

    /// Deliberately not a `ContentUnavailableView`.
    ///
    /// That control's description paragraph is precisely the shape this column
    /// cannot afford — see the width discipline above. Two short lines say the
    /// same thing and fit.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            Image(systemName: "waveform")
                .font(.title)
                .foregroundStyle(.tertiary)

            Text("No recordings yet")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button("Start Recording") {
                services.navigation.select(.record)
            }
            .controlSize(.small)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if services.recorder.isActive {
                recordingIndicator
                Divider()
            }
            if services.speakerModelState.isPreparing {
                modelPreparation
                Divider()
            }
            storagePath
        }
        .background(.bar)
    }

    /// A red dot and a running clock whenever a recording is live — on *every*
    /// tab.
    ///
    /// The session belongs to ``AppServices``, not to ``RecordView``, so it has
    /// always kept running when you navigate away. What was missing was any way
    /// to tell: leave the record screen and every trace of the recording left
    /// the window with it, which is a bad thing to be unsure about when the
    /// thing running is a meeting you cannot re-record.
    ///
    /// It lives here rather than in the toolbar for two reasons: this column is
    /// present on every tab, which is the same promise the old sidebar row made;
    /// and it costs no toolbar width, which is the scarce resource now that the
    /// tab bar shares that space with the editor's own buttons.
    ///
    /// Two deliberate restraints, both inherited from the row it replaces:
    ///
    /// - It reads ``RecordingSessionModel/elapsedSeconds``, never `elapsed`.
    ///   This view is on screen in every tab, and under Observation the 10 Hz
    ///   property would re-render the whole window ten times a second.
    /// - The dot does not pulse. An animation here would keep the window
    ///   redrawing forever for decoration, and this app has already paid once
    ///   for a main thread that could not keep up.
    private var recordingIndicator: some View {
        let session = services.recorder
        let isPaused = session.phase == .paused

        return Button {
            services.navigation.select(.record)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isPaused ? "pause.fill" : "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                Text(isPaused ? "Paused" : "Recording")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Display.duration(TimeInterval(session.elapsedSeconds)))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isPaused
                ? "Recording paused at \(session.elapsedSeconds) seconds"
                : "Recording in progress, \(session.elapsedSeconds) seconds"
        )
        .help(
            isPaused
                ? "A recording is paused. Click to open Record and resume it."
                : "A recording is in progress. Click to open Record and pause or stop it."
        )
    }

    /// The ~100 MB one-time model download. Without this the first "Matching
    /// speakers" looks like a hang for several minutes.
    private var modelPreparation: some View {
        // Indeterminate until the downloader reports a fraction, which it only
        // does once it knows the total size.
        let raw = services.speakerModelState.fractionCompleted
        let fraction: Double? = raw > 0 ? raw : nil

        return VStack(alignment: .leading, spacing: 4) {
            Text("Preparing speaker models")
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            ProgressView(value: fraction, total: 1.0)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .help(services.speakerModelState.message ?? "Downloading the on-device voice models.")
    }

    /// Where the files are, stated rather than merely reachable.
    ///
    /// The first thing a real user wanted to know was *where recordings are
    /// saved*, and an icon offers an action without answering the question. A
    /// footer answers it at a glance, is present in the empty state too (when
    /// the question is most likely), and clicking it opens Finder — so it is
    /// both the answer and the action. Modelled on Finder's own path bar;
    /// deliberately quiet.
    private var storagePath: some View {
        Button {
            FinderIntegration.open(services.libraryRoot)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(Display.friendlyPath(services.libraryRoot))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .help("Recordings are saved here. Click to open \(services.libraryRoot.path) in Finder.")
        .accessibilityLabel("Recordings folder: \(services.libraryRoot.path). Opens in Finder.")
    }
}
