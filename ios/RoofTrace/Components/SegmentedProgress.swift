import SwiftUI

struct SegmentedProgress: View {
    let fraction: Double
    let segmentCount: Int

    init(fraction: Double, segmentCount: Int) {
        self.fraction = fraction
        self.segmentCount = max(1, segmentCount)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<segmentCount, id: \.self) { index in
                Capsule()
                    .fill(index < filledSegments ? Color.CC.blue : Color.CC.line)
                    .frame(height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Measurement progress")
        .accessibilityValue("\(Int(clampedFraction * 100)) percent")
    }

    private var clampedFraction: Double {
        min(max(fraction, 0), 1)
    }

    private var filledSegments: Int {
        guard clampedFraction > 0 else { return 0 }
        return min(segmentCount, max(1, Int(ceil(clampedFraction * Double(segmentCount)))))
    }
}
