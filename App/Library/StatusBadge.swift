import KVoiceCore
import SwiftUI

/// The spec's progress vocabulary as a list badge:
/// `Uploading → Queued → Transcribing → Matching speakers → Done / Failed`.
///
/// The words come from `TranscriptionStage.displayName` in Core, so the badge,
/// the CLI, and any future surface cannot drift apart.
struct StatusBadge: View {

    let status: RecordingStatus
    /// The job's detail line — failure text, transcript id, speakers matched.
    var detail: String?

    private var label: String {
        status.stage?.displayName ?? status.displayName
    }

    private var tint: Color {
        switch status {
        case .recorded: return .secondary
        case .uploading, .queued, .transcribing, .matching: return .accentColor
        case .done: return .green
        case .failed: return .red
        }
    }

    private var symbol: String {
        switch status {
        case .recorded: return "waveform"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .uploading, .queued, .transcribing, .matching: return "circle.dashed"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status.isInFlight {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: symbol)
                    .imageScale(.small)
            }
            Text(label)
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .help(helpText)
        .accessibilityLabel("Status: \(label)")
    }

    private var helpText: String {
        if let message = status.failureMessage { return message }
        if let detail { return "\(label) — \(detail)" }
        return label
    }
}
