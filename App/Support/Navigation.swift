import Foundation
import Observation

/// Sections in the sidebar.
///
/// Phase 6 added `people`, which cost exactly what this enum was built to cost:
/// a case here and a view in ``RootView``. Settings is deliberately *not* a
/// case — it is a `Settings` scene (⌘,), where macOS users expect it.
enum SidebarSection: String, Hashable, Identifiable, CaseIterable {
    case record
    case recordings
    case people

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: return "Record"
        case .recordings: return "Recordings"
        case .people: return "People"
        }
    }

    var symbol: String {
        switch self {
        case .record: return "mic.circle"
        case .recordings: return "waveform"
        case .people: return "person.2"
        }
    }
}

/// Which section the window is showing.
///
/// Shared rather than local `@State` so that a view deep in the hierarchy — the
/// "Show in Library" button on a saved recording, the empty state's "Start
/// Recording" — can move the window without threading a binding through.
@MainActor
@Observable
final class NavigationModel {
    var section: SidebarSection? = .record
}
