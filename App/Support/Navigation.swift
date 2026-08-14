import Foundation
import Observation

/// Sections in the sidebar.
///
/// v1 ships two. `people` and the rest of Settings arrive in Phase 6 — adding
/// them is a case here plus a view in ``RootView``, which is the seam this
/// enum exists to keep clean.
enum SidebarSection: String, Hashable, Identifiable, CaseIterable {
    case record
    case recordings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: return "Record"
        case .recordings: return "Recordings"
        }
    }

    var symbol: String {
        switch self {
        case .record: return "mic.circle"
        case .recordings: return "waveform"
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
