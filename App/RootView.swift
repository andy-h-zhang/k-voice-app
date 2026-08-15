import SwiftUI

/// The window: a standard `NavigationSplitView` with the app's sections in the
/// sidebar.
///
/// Two columns rather than three. Sections that need their own list-plus-detail
/// — People does, and Phase 5's transcript editor will — split *inside* the
/// detail column (see ``PeopleView``) rather than turning this into a
/// three-column view, so one section's shape never dictates another's.
struct RootView: View {

    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var navigation = services.navigation

        NavigationSplitView {
            List(selection: $navigation.section) {
                Section("Capture") {
                    row(.record)
                }
                Section("Library") {
                    row(.recordings)
                }
                Section("Voices") {
                    row(.people)
                }
            }
            // A real range, and one the window can always honour.
            //
            // 180…260 was only 80 points of travel, which is why dragging the
            // divider felt like it did nothing: the sidebar was, for practical
            // purposes, a fixed column. 160…420 gives 260 points, so the
            // divider is worth dragging and a wide window can afford a wide
            // sidebar.
            //
            // The floor is the load-bearing number. `NavigationSplitView`
            // *collapses* the sidebar — the "left panel disappeared" failure —
            // only when the window cannot fit `sidebar min + detail min`. So
            // that sum has to stay under the window's own 720-point floor
            // (`KVoiceApp`), with room to spare:
            //
            //     160 (here) + 440 (People, the widest detail) = 600 ≤ 720
            //
            // 120 points of slack. Above the floor the split view *squeezes*
            // the sidebar instead of dropping it, which is exactly the
            // "adjusts as I resize the window" behaviour asked for: drag the
            // window narrow and the sidebar gives ground down to 160 before
            // the detail column yields anything. The ceiling is deliberately
            // not bounded by that sum — a 420-point sidebar in a 720-point
            // window simply squeezes back to 720 − 440 = 280, which is still
            // far above the floor, so no width the user can choose here can
            // ever make the sidebar vanish.
            .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 420)
        } detail: {
            Group {
                switch navigation.section {
                case .record, .none:
                    RecordView()
                case .recordings:
                    LibraryView()
                case .people:
                    PeopleView()
                }
            }
            // Every section fills the detail column, so switching sections
            // hands AppKit the same layout report rather than a new preferred
            // size to resize the window to. Without this, a section whose
            // content has a smaller ideal size drags the window down with it —
            // the "switching menus resizes the window back to default" bug.
            //
            // `idealWidth`/`idealHeight` are the load-bearing part, and they are
            // what keeps the sidebar on screen. `NavigationSplitView` sizes its
            // columns from what the detail *reports* it would like, and a
            // `Text` marked `.fixedSize(horizontal: false, vertical: true)` —
            // the idiom this app uses in every banner and empty state to stop
            // macOS truncating a paragraph — reports the width of the whole
            // string on one line. That is well over a thousand points, it
            // propagates all the way up here, and the split view answers it by
            // squeezing the sidebar until its rows have no room left to draw:
            // the "left panel is empty and I can't click anything" bug, in
            // People (whose empty state is mostly such paragraphs) and on the
            // record screen the moment a banner appears — which is exactly what
            // pressing Stop does.
            //
            // A stated ideal ends the negotiation. The detail column now always
            // answers 640×480 no matter what is inside it, the sidebar keeps
            // the width its own `navigationSplitViewColumnWidth` asks for, and
            // paragraphs go back to wrapping inside whatever width they are
            // actually given.
            .frame(
                minWidth: 0,
                idealWidth: 640,
                maxWidth: .infinity,
                minHeight: 0,
                idealHeight: 480,
                maxHeight: .infinity
            )
            // The library player's only controls are on the library rows, so
            // leaving a two-hour meeting playing behind another section would
            // give the user audio with no way to stop it.
            .onChange(of: navigation.section) { _, section in
                if section != .recordings { services.libraryPlayback.stop() }
            }
        }
    }

    private func row(_ section: SidebarSection) -> some View {
        HStack(spacing: 6) {
            Label(section.title, systemImage: section.symbol)
                .lineLimit(1)
            if section == .record {
                Spacer(minLength: 4)
                recordingIndicator
            }
        }
        .tag(section)
    }

    /// A red dot and a running clock, on the Record row, whenever a recording
    /// is live — in *every* section.
    ///
    /// The session belongs to ``AppServices``, not to ``RecordView``, so it has
    /// always kept running when you navigate away. What was missing was any way
    /// to tell: leave the record screen and every trace of the recording left
    /// the window with it, which is a bad thing to be unsure about when the
    /// thing running is a meeting you cannot re-record. The quit guard
    /// (``AppQuitGuard``) still stands between a live recording and
    /// termination; this is the same promise made visible.
    ///
    /// Two deliberate restraints:
    ///
    /// - It reads ``RecordingSessionModel/elapsedSeconds``, never `elapsed`.
    ///   This view is on screen in every section, and under Observation the
    ///   10 Hz property would re-render the whole window ten times a second.
    /// - The dot does not pulse. An animation here would keep the window
    ///   redrawing forever for decoration, and this app has just finished
    ///   paying for a main thread that could not keep up.
    @ViewBuilder
    private var recordingIndicator: some View {
        let session = services.recorder
        let isPaused = session.phase == .paused

        if session.phase == .recording || isPaused {
            HStack(spacing: 4) {
                Image(systemName: isPaused ? "pause.fill" : "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                Text(Display.duration(TimeInterval(session.elapsedSeconds)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                isPaused
                    ? "Recording paused at \(session.elapsedSeconds) seconds"
                    : "Recording in progress, \(session.elapsedSeconds) seconds"
            )
            .help(
                isPaused
                    ? "A recording is paused. Open Record to resume it."
                    : "A recording is in progress. Open Record to pause or stop it."
            )
        }
    }
}

/// Shown when the app cannot open its library or its database.
///
/// A meeting recorder that dies silently on launch is worse than one that says
/// which folder it could not open, so this names the path and offers Finder.
struct BootstrapFailureView: View {

    let message: String
    let path: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("KVoice could not open its library")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Library folder", value: path)
                .frame(maxWidth: 420)

            Button("Show in Finder") {
                FinderIntegration.reveal(URL(fileURLWithPath: path))
            }
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 380)
    }
}
