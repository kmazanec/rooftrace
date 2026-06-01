import SwiftUI

struct StatProbe: View {
    let label: String
    let value: String
    let unit: String?
    var isHero = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.RoofTrace.label)
                .foregroundStyle(Color.Brand.gray600)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(isHero ? .RoofTrace.monoXL : .system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.Brand.charcoal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.RoofTrace.label)
                        .foregroundStyle(Color.Brand.gray600)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ConfidenceChip: View {
    let confidence: Double?

    private var level: ConfidenceLevel {
        ConfidenceLevel(confidence)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: level.symbolName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(level.color)
            Text(level.label)
                .font(.RoofTrace.label)
                .foregroundStyle(Color.Brand.gray700)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.Brand.gray100)
        .overlay(
            Capsule()
                .stroke(Color.Brand.gray300, lineWidth: 1)
        )
        .clipShape(Capsule())
        .accessibilityLabel("Confidence \(level.label)")
    }
}

struct FacetSwatch: View {
    let index: Int
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.Brand.charcoal.opacity(isSelected ? 0.52 : 0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.Brand.charcoal : Color.Brand.gray300, lineWidth: isSelected ? 2 : 1)
            )
            .frame(width: 22, height: 14)
            .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.RoofTrace.headline)
                .foregroundStyle(Color.Brand.charcoal)
            if let subtitle {
                Text(subtitle)
                    .font(.RoofTrace.label)
                    .foregroundStyle(Color.Brand.gray600)
            }
        }
    }
}

enum ConfidenceLevel {
    case high
    case medium
    case low
    case unknown

    init(_ confidence: Double?) {
        guard let confidence else {
            self = .unknown
            return
        }
        if confidence >= 0.75 {
            self = .high
        } else if confidence >= 0.5 {
            self = .medium
        } else {
            self = .low
        }
    }

    var label: String {
        switch self {
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        case .unknown: "unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .high: "circle.fill"
        case .medium: "diamond.fill"
        case .low: "triangle.fill"
        case .unknown: "square.fill"
        }
    }

    var color: Color {
        switch self {
        case .high: Color.Brand.confidenceHigh
        case .medium: Color.Brand.confidenceMedium
        case .low: Color.Brand.confidenceLow
        case .unknown: Color.Brand.gray500
        }
    }
}
