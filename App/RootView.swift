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
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ section: SidebarSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .tag(section)
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
