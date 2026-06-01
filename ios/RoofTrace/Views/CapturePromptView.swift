import SwiftUI

/// A single walk-around prompt: title + 2D illustration + instruction + compass
/// hint + "Tap when ready". No live AR overlay (ADR-007). The button is disabled
/// while GPS accuracy is still poor or a capture is in flight.
struct CapturePromptView: View {
    @Bindable var model: CaptureViewModel
    let prompt: PromptStep

    var body: some View {
        ZStack {
            Color.CC.chalk.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Step")
                        .font(.RoofTrace.label)
                        .foregroundStyle(Color.CC.ink55)
                    Text("\(prompt.captureIndex + 1) OF \(CaptureSessionState.promptCount)")
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.CC.ink)
                    Spacer()
                }

                SegmentedProgress(
                    fraction: Double(prompt.captureIndex + 1) / Double(CaptureSessionState.promptCount),
                    segmentCount: CaptureSessionState.promptCount
                )

                ScreenHeader(
                    eyebrow: "Walk-around",
                    title: prompt.title,
                    subtitle: prompt.instruction
                )

                CompassCard(symbolName: prompt.symbolName, bearingDegrees: prompt.bearingDegrees)

                if !model.gpsReady {
                    InlineErrorBlock(message: "Waiting for GPS accuracy before this capture.")
                }

                Spacer()

                PrimaryButton(
                    title: "Tap when ready",
                    isLoading: model.captureInFlight,
                    isDisabled: !model.gpsReady
                ) {
                    Task { await model.capture() }
                }
            }
            .padding(20)
        }
    }
}

/// A static compass needle pointing to the prompt's bearing (no live heading —
/// ADR-007 keeps the capture flow free of live AR/sensors overlays).
struct CompassCard: View {
    let symbolName: String
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
        Card {
            VStack(spacing: 18) {
                Image(systemName: symbolName)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(Color.CC.blue)
                    .accessibilityHidden(true)

                ZStack {
                    Circle()
                        .fill(Color.CC.ink)
                        .frame(width: 148, height: 148)
                    Circle()
                        .stroke(Color.CC.chalk.opacity(0.35), lineWidth: 1)
                        .frame(width: 116, height: 116)
                    ForEach(["N", "E", "S", "W"].indices, id: \.self) { index in
                        let labels = ["N", "E", "S", "W"]
                        Text(labels[index])
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.CC.chalk)
                            .offset(y: -62)
                            .rotationEffect(.degrees(Double(index) * 90))
                    }
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(Color.CC.orangeHigh)
                        .rotationEffect(.degrees(bearingDegrees))
                }

                Text("Face \(cardinalName)")
                    .font(.RoofTrace.bodyMedium)
                    .foregroundStyle(Color.CC.ink)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Face about \(cardinalName), \(Int(bearingDegrees)) degrees")
    }
}
