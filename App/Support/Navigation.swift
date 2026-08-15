import Foundation
import Observation

/// The three modes in the window's tab bar.
///
/// Settings is one of them. It used to be a `Settings` scene behind ⌘, — the
/// macOS convention — and that convention assumes settings are a place you visit
/// rarely and briefly. This app's are not: the API key gates transcription
/// entirely, and the input device and matching threshold are things you change
/// while looking at the thing they affect. A separate window meant every one of
/// those trips left the app.
enum AppTab: String, Hashable, Identifiable, CaseIterable {
    case record
    case people
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: return "Record"
        case .people: return "People"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .record: return "mic.circle"
        case .people: return "person.2"
        case .settings: return "gearshape"
        }
    }
}

/// What the main body is showing: one of the tabs, or one recording.
enum WindowRoute: Hashable {
    case tab(AppTab)
    case recording(UUID)
}

/// Which of those the window is showing.
///
/// Shared rather than local `@State` so that a view deep in the hierarchy — the
/// "Show in Library" button on a saved recording, the sidebar's "Start
/// Recording", every "Open Settings…" — can move the window without threading a
/// binding through.
///
/// ## Why one stored value and two computed bindings
///
/// The tab bar and the recordings sidebar both drive the main body, and the two
/// are mutually exclusive: opening a recording must un-highlight the tabs, and
/// picking a tab must clear the recording selection. Two stored properties kept
/// in step by `onChange` handlers would make that a matter of ordering — and
/// ordering bugs here look like a window showing two things at once, or nothing.
///
/// Storing the *route* and deriving both selections from it makes the exclusion
/// structural. There is no state in which both bindings are non-nil, so there is
/// no ordering to get wrong.
@MainActor
@Observable
final class NavigationModel {

    private(set) var route: WindowRoute = .tab(.record)

    /// Where deselecting a recording lands.
    ///
    /// The last tab actually chosen, rather than always Record: someone who was
    /// working in People, clicked a recording and then dismissed it expects
    /// People back, not the record screen.
    private var lastTab: AppTab = .record

    /// Binding for the toolbar's segmented picker.
    ///
    /// Reads `nil` — no segment highlighted — whenever a recording is open. That
    /// nil *is* the mutual exclusion, which is why the type is optional. Writes
    /// of nil are ignored: a segmented picker never produces one, and swallowing
    /// it keeps the two adapters from fighting over the same route.
    var selectedTab: AppTab? {
        get {
            if case .tab(let tab) = route { return tab }
            return nil
        }
        set {
            guard let newValue else { return }
            select(newValue)
        }
    }

    /// Binding for the sidebar's `List(selection:)`. Nil while a tab is showing.
    var selectedRecording: UUID? {
        get {
            if case .recording(let id) = route { return id }
            return nil
        }
        set {
            if let newValue {
                route = .recording(newValue)
            } else if case .recording = route {
                route = .tab(lastTab)
            }
        }
    }

    func select(_ tab: AppTab) {
        lastTab = tab
        route = .tab(tab)
    }

    func openRecording(_ id: UUID) {
        route = .recording(id)
    }

    /// The open recording just left the library.
    ///
    /// Called before a delete rather than after, so the body never spends a
    /// frame pointed at a row that no longer exists.
    func recordingWasRemoved(_ id: UUID) {
        if case .recording(id) = route { route = .tab(lastTab) }
    }
}
