import KVoiceCore
import SwiftUI

/// The Settings scene, Phase 4 edition.
///
/// Phase 6 owns Settings and will add the storage-folder picker (with
/// migration), the similarity-threshold slider, the keyterms editor, the
/// default export format, and the input-device picker. Only the **API key** is
/// here now, because without it nothing in the app can transcribe — and no key
/// exists in this installation, so "add your key in Settings" has to lead
/// somewhere real. Everything else is shown read-only, which also documents
/// what the later phase fills in.
struct AppSettingsView: View {

    @Environment(AppServices.self) private var services

    @State private var draftKey = ""
    @State private var saveError: String?
    @State private var didSave = false

    var body: some View {
        Form {
            Section {
                if services.apiKeyComesFromEnvironment {
                    LabeledContent("API key") {
                        Text("Supplied by \(APIKeyResolver.environmentVariable)")
                            .foregroundStyle(.secondary)
                    }
                } else if services.hasAPIKey {
                    LabeledContent("API key") {
                        HStack(spacing: 8) {
                            Label("Saved in your login Keychain", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Remove") { remove() }
                        }
                    }
                } else {
                    keyEntry
                }

                if let saveError {
                    Text(saveError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("AssemblyAI")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        services.apiKeyComesFromEnvironment
                            ? "The environment variable wins over anything saved here. Unset it to use a stored key."
                            : "Stored in the login Keychain, never in a preferences file."
                    )
                    Link(
                        "Get a key at assemblyai.com/dashboard",
                        destination: URL(string: "https://www.assemblyai.com/dashboard")!
                    )
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Library folder") {
                    HStack(spacing: 8) {
                        Text(services.libraryRoot.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") {
                            FinderIntegration.open(services.libraryRoot)
                        }
                    }
                }
            }

            Section {
                LabeledContent("Input device", value: "System default")
                LabeledContent(
                    "Similarity threshold",
                    value: String(format: "%.2f", services.settings.similarityThreshold)
                )
                LabeledContent("Keyterms", value: keytermsSummary)
                LabeledContent(
                    "Default export format",
                    value: services.settings.defaultExportFormat.rawValue.capitalized
                )
            } header: {
                Text("Transcription")
            } footer: {
                Text("These become editable when People and Settings ship in a later phase.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var keytermsSummary: String {
        let count = services.settings.keyterms.count
        return count == 0 ? "None" : "\(count) term\(count == 1 ? "" : "s")"
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    SecureField("Paste your key", text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if didSave {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    private func save() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try services.saveAPIKey(key)
            draftKey = ""
            saveError = nil
            didSave = true
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func remove() {
        do {
            try services.removeAPIKey()
            saveError = nil
            didSave = false
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
