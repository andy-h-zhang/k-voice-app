import SwiftUI

/// KVoice — a meeting recorder with speaker-aware transcription.
///
/// The app is a thin shell: `KVoiceCore` owns recording, transcription,
/// speaker identification, storage, and persistence, and everything here
/// observes it. ``AppServices`` is built once at launch and reaches the views
/// through the environment.
@main
struct KVoiceApp: App {

    /// Only for the quit guard (spec §Core pipeline 1: a confirm dialog must
    /// stand between a running recording and termination).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var bootstrap = AppBootstrap.make()

    var body: some Scene {
        WindowGroup {
            switch bootstrap {
            case .ready(let services):
                RootView()
                    .environment(services)
            case .failed(let message, let path):
                BootstrapFailureView(message: message, path: path)
            }
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            switch bootstrap {
            case .ready(let services):
                AppSettingsView()
                    .environment(services)
            case .failed(let message, let path):
                BootstrapFailureView(message: message, path: path)
            }
        }
    }
}
