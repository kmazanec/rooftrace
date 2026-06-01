import SwiftUI

struct StatusIndicator: View {
    enum Kind: Equatable {
        case working
        case done
        case failed
    }

    struct Model: Equatable {
        let kind: Kind
        let label: String
        let systemImageName: String

        init(status: JobStatus) {
            switch status {
            case .pending:
                kind = .working
                label = "Queued"
                systemImageName = "clock"
            case .processing(let stage):
                kind = .working
                label = stage.label
                systemImageName = "arrow.triangle.2.circlepath"
            case .ready:
                kind = .done
                label = "Ready"
                systemImageName = "checkmark"
            case .failed:
                kind = .failed
                label = "Failed"
                systemImageName = "exclamationmark"
            case .unknown:
                kind = .failed
                label = "Unknown"
                systemImageName = "questionmark"
            }
        }

        var foreground: Color {
            switch kind {
            case .working:
                Color.CC.blue
            case .done:
                Color.CC.ink
            case .failed:
                Color.CC.orangeHigh
            }
        }

        var background: Color {
            switch kind {
            case .working:
                Color.CC.blue.opacity(0.10)
            case .done:
                Color.CC.line
            case .failed:
                Color.CC.orange.opacity(0.18)
            }
        }
    }

    let model: Model

    init(status: JobStatus) {
        model = Model(status: status)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.systemImageName)
                .font(.system(size: 11, weight: .semibold))
            Text(model.label)
                .font(.RoofTrace.label)
                .lineLimit(1)
        }
        .foregroundStyle(model.foreground)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(model.background)
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}

private extension Stage {
    var label: String {
        switch self {
        case .resolvingAddress:
            "Resolving address"
        case .fetchingImagery:
            "Fetching imagery"
        case .fetchingLidar:
            "Fetching LiDAR"
        case .refiningOutline:
            "Refining outline"
        case .detectingFeatures:
            "Detecting features"
        case .fittingPlanes:
            "Fitting planes"
        }
    }
}
