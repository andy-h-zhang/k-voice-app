import SwiftUI

/// The window: a standard `NavigationSplitView` with the app's sections in the
/// sidebar.
///
/// Two columns rather than three because Phase 4 has no transcript editor yet.
/// Phase 5 turns the recordings detail into its own split — the seam is
/// ``LibraryModel/selection``, which already tracks the selected row.
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
                // Phase 6 adds People here, alongside the Settings scene.
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch navigation.section {
            case .record, .none:
                RecordView()
            case .recordings:
                LibraryView()
            }
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
