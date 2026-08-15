import KVoiceCore
import SwiftUI

/// The spec's progress vocabulary as a list badge:
/// `Uploading → Queued → Transcribing → Matching speakers → Done / Failed`.
///
/// The words come from `TranscriptionStage.displayName` in Core, so the badge,
/// the CLI, and any future surface cannot drift apart.
struct StatusBadge: View {

    /// How much room the badge has.
    enum Style {
        /// The full capsule: symbol and words. For anywhere with a row's width
        /// to spend.
        case capsule
        /// Symbol only, with the words moved into the tooltip — and *nothing at
        /// all* for a recording that is merely recorded, which is the resting
        /// state of every row and so says nothing worth a glyph.
        ///
        /// For the sidebar, where the title needs every point it can get.
        case glyph
    }

    let status: RecordingStatus
    /// The job's detail line — failure text, transcript id, speakers matched.
    var detail: String?
    var style: Style = .capsule

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
        switch style {
        case .capsule:
            capsuleBody
        case .glyph:
            glyphBody
        }
    }

    private var capsuleBody: some View {
        HStack(spacing: 5) {
            indicator
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

    @ViewBuilder
    private var glyphBody: some View {
        // `.recorded` draws nothing. It is the state every recording starts in
        // and, with no API key configured, the state every recording stays in —
        // so a glyph for it would mark every row alike and mean nothing.
        if status.kind != .recorded {
            indicator
                .font(.caption)
                .foregroundStyle(tint)
                .help(helpText)
                .accessibilityLabel("Status: \(label)")
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if status.isInFlight {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 10, height: 10)
        } else {
            Image(systemName: symbol)
                .imageScale(.small)
        }
    }

    private var helpText: String {
        if let message = status.failureMessage { return message }
        if let detail { return "\(label) — \(detail)" }
        return label
    }
}
