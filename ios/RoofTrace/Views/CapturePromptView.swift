import SwiftUI

/// A single walk-around prompt: title + 2D illustration + instruction + compass
/// hint + "Tap when ready". No live AR overlay (ADR-007). The button is disabled
/// while GPS accuracy is still poor or a capture is in flight.
struct CapturePromptView: View {
    @Bindable var model: CaptureViewModel
    let prompt: PromptStep

    var body: some View {
        VStack(spacing: 20) {
            Text("Step \(prompt.captureIndex + 1) of \(CaptureSessionState.promptCount)")
                .font(.caption).foregroundStyle(.secondary)
            Text(prompt.title)
                .font(.title2).bold()

            Image(systemName: prompt.symbolName)
                .font(.system(size: 96))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            CompassNeedle(bearingDegrees: prompt.bearingDegrees)
                .frame(width: 120, height: 120)

            Text(prompt.instruction)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            if !model.gpsReady {
                Text("Waiting for GPS accuracy…")
                    .font(.caption).foregroundStyle(.orange)
            }

            Button {
                Task { await model.capture() }
            } label: {
                Text("Tap when ready").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.gpsReady || model.captureInFlight)
        }
        .padding()
    }
}

/// A static compass needle pointing to the prompt's bearing (no live heading —
/// ADR-007 keeps the capture flow free of live AR/sensors overlays).
struct CompassNeedle: View {
    let bearingDegrees: Double

    /// Maps a bearing in degrees (0 = North, clockwise) to the nearest cardinal
    /// or intercardinal direction name.
    private var cardinalName: String {
        let normalized = bearingDegrees.truncatingRemainder(dividingBy: 360)
        let adjusted = normalized < 0 ? normalized + 360 : normalized
        switch adjusted {
        case 337.5..<360, 0..<22.5:   return "north"
        case 22.5..<67.5:             return "northeast"
        case 67.5..<112.5:            return "east"
        case 112.5..<157.5:           return "southeast"
        case 157.5..<202.5:           return "south"
        case 202.5..<247.5:           return "southwest"
        case 247.5..<292.5:           return "west"
        default:                      return "northwest"
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.secondary, lineWidth: 2)
            Image(systemName: "location.north.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .rotationEffect(.degrees(bearingDegrees))
            VStack {
                Text("N").font(.caption2).offset(y: -4)
                Spacer()
            }
        }
        .accessibilityLabel("Face about \(cardinalName), \(Int(bearingDegrees)) degrees")
    }
}
