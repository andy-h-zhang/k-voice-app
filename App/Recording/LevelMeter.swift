import SwiftUI

/// Input level meter, fed by `MicSource.levelStream` (~15 Hz, 0…1).
///
/// The bar is what tells a user "the microphone is hearing you" before they
/// trust a 60-minute meeting to it — so it stays visible (and empty) when idle
/// rather than appearing only once recording starts.
struct LevelMeter: View {

    let level: Float
    var isActive: Bool = true

    private var clamped: Double { Double(min(max(level, 0), 1)) }

    private var fillColor: Color {
        guard isActive else { return .secondary }
        // Nearing clipping is worth noticing while there is still time to move
        // the microphone.
        switch clamped {
        case ..<0.75: return .green
        case ..<0.92: return .yellow
        default: return .red
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(0, geometry.size.width * clamped))
                    .animation(.linear(duration: 0.08), value: clamped)
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(clamped * 100)) percent")
    }
}
