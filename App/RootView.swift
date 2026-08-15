import SwiftUI

/// The window: recordings down the left, three tabs across the top, and one
/// thing at a time in the middle.
///
/// The sidebar holds the app's *content* — every recording, newest first —
/// rather than its modes. Modes are the three tabs in the toolbar, and a tab and
/// a recording are mutually exclusive: exactly one of the four possible things
/// is in the main body at any moment. See ``NavigationModel`` for why that
/// exclusion is structural rather than enforced by hand.
struct RootView: View {

    @Environment(AppServices.self) private var services

    /// Pinned open. `NavigationSplitView` will still collapse the sidebar if the
    /// window cannot fit `sidebar min + detail min` — the width budget is spelled
    /// out below — but nothing should collapse it on a whim, because it is now
    /// the only way to reach a recording.
    @State private var columns: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        @Bindable var navigation = services.navigation

        NavigationSplitView(columnVisibility: $columns) {
            RecordingsSidebar()
                // A real range, and one the window can always honour.
                //
                // The floor is the load-bearing number. `NavigationSplitView`
                // *collapses* the sidebar — the "left panel disappeared"
                // failure — only when the window cannot fit `sidebar min +
                // detail min`. So that sum has to stay under the window's own
                // 720-point floor (`KVoiceApp`), with room to spare. The detail
                // column below asks for no minimum at all, which leaves the
                // whole budget to this column and its content.
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            Group {
                switch navigation.route {
                case .tab(.record):
                    RecordView()
                case .tab(.people):
                    PeopleView()
                case .tab(.settings):
                    AppSettingsView()
                case .recording(let id) where services.library.row(id: id) != nil:
                    // `.id(id)` is not decoration, and removing it loses the
                    // user's work.
                    //
                    // Going from one recording to another puts the same view
                    // type in the same structural position, so SwiftUI updates
                    // it in place and **never calls `onDisappear`** — and
                    // `onDisappear` is what runs `flushPendingEdits()`
                    // (`TranscriptEditorView`). Worse, the editor's
                    // `.task(id: recordingID)` *would* fire, rebuilding the
                    // model and throwing the un-flushed keystrokes away with the
                    // old one. Typing in a transcript and clicking the next
                    // recording would silently lose the last sentence.
                    //
                    // Changing the identity forces a real teardown, so the
                    // flush, the audio release and the library reload all run
                    // before the next editor is built. The new instance's
                    // `.task` may start before the old one's `onDisappear`
                    // finishes; that is harmless, because every statement in
                    // that handler acts on state the *old* instance owns or is
                    // idempotent.
                    TranscriptEditorScreen(recordingID: id)
                        .id(id)
                default:
                    // A route pointing at a recording that is no longer in the
                    // library — deleted in Finder, or removed by another window.
                    // Showing the record screen beats showing nothing.
                    RecordView()
                }
            }
            // Every section fills the detail column, so switching sections hands
            // AppKit the same layout report rather than a new preferred size to
            // resize the window to.
            //
            // `idealWidth`/`idealHeight` are the load-bearing part, and they are
            // what keeps the sidebar on screen. `NavigationSplitView` sizes its
            // columns from what the detail *reports* it would like, and a `Text`
            // marked `.fixedSize(horizontal: false, vertical: true)` — the idiom
            // this app uses in every banner and empty state to stop macOS
            // truncating a paragraph — reports the width of the whole string on
            // one line. That is well over a thousand points, it propagates all
            // the way up here, and the split view answers it by squeezing the
            // sidebar until its rows have no room left to draw.
            //
            // A stated ideal ends the negotiation. It has to stay *outside* the
            // switch, enclosing every branch: Settings is now one of them, and
            // its grouped form carries three such paragraphs of its own.
            .frame(
                minWidth: 0,
                idealWidth: 640,
                maxWidth: .infinity,
                minHeight: 0,
                idealHeight: 480,
                maxHeight: .infinity
            )
            .toolbar {
                // Declared here rather than inside the switch, so the tab bar is
                // not torn down and rebuilt every time the route changes.
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $navigation.selectedTab) {
                        ForEach(AppTab.allCases) { tab in
                            // Tagged with the *optional* type: that is what makes
                            // "no tab selected" a legitimately unmatched value
                            // rather than an invalid selection, and it is how a
                            // recording being open leaves all three segments
                            // unhighlighted.
                            Text(tab.title).tag(Optional(tab))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Record, manage voice profiles, or change settings")
                }
            }
        }
        // Hoisted out of the library screen: these errors now come from the
        // sidebar's own actions *and* from the editor's export handler, so the
        // alert has to be somewhere that presents whatever the route is.
        .alert(
            "Library problem",
            isPresented: Binding(
                get: { services.library.errorMessage != nil },
                set: { if !$0 { services.library.errorMessage = nil } }
            ),
            presenting: services.library.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
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
