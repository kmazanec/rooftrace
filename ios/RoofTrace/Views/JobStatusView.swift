import SwiftUI

struct JobStatusView: View {
    @Bindable var router: AppRouter
    @State var model: StatusPollViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: StatusPollViewModel, router: AppRouter) {
        _model = State(initialValue: model)
        self.router = router
    }

    var body: some View {
        ZStack {
            Color.CC.chalk.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(
                        eyebrow: "Measurement",
                        title: model.address,
                        subtitle: headline
                    )

                    Card {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                StatusIndicator(status: model.status)
                                Spacer()
                                if model.isPolling {
                                    ProgressView()
                                        .tint(Color.CC.blue)
                                }
                            }

                            SegmentedProgress(
                                fraction: model.progressFraction,
                                segmentCount: Stage.allCases.count
                            )

                            VStack(spacing: 0) {
                                ForEach(model.timelineItems) { item in
                                    TimelineRow(
                                        item: item,
                                        isLast: item.stage == Stage.allCases.last,
                                        reduceMotion: reduceMotion
                                    )
                                }
                            }
                        }
                    }

                    if let transientMessage = model.transientMessage {
                        InlineErrorBlock(message: transientMessage)
                    }

                    terminalActions

                    scanAction
                }
                .padding(20)
            }
        }
        .navigationTitle("Status")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.jobID) {
            await model.pollUntilTerminal()
        }
    }

    private var headline: String {
        switch model.status {
        case .pending:
            return "Queued and waiting for the measurement pipeline."
        case .processing(let stage):
            return stage.subtitle
        case .ready:
            return "The roof measurement is ready to review."
        case .failed:
            return "The measurement stopped before it could finish."
        case .unknown:
            return "Checking this job's current state."
        }
    }

    @ViewBuilder
    private var terminalActions: some View {
        if let locator = model.readyLocator {
            PrimaryButton(title: "View report") {
                router.push(.report(jobID: locator.jobID))
            }
        } else if let reason = model.failedReason {
            VStack(alignment: .leading, spacing: 12) {
                InlineErrorBlock(message: "We could not finish this measurement. \(reason)")

                PrimaryButton(title: "Try again", isLoading: model.isPolling) {
                    Task { await model.retry() }
                }

                GhostButton(title: "Back to jobs", systemImage: "chevron.left") {
                    router.pop()
                }
            }
        }
    }

    /// The LiDAR walk-around entry point. Available whenever the job has an
    /// unexpired capture credential — recovered from the status response, or
    /// from the in-memory handoff stored when this device created the job — so a
    /// contractor can scan to improve or rescue the measurement at any stage.
    @ViewBuilder
    private var scanAction: some View {
        if let handoff = scanHandoff, model.shouldShowScanAction {
            VStack(alignment: .leading, spacing: 8) {
                GhostButton(title: scanTitle, systemImage: "camera.viewfinder") {
                    router.push(.capture(handoff))
                }

                Text(scanCaption)
                    .font(.RoofTrace.label)
                    .foregroundStyle(Color.CC.ink75)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scanHandoff: CaptureHandoff? {
        model.captureHandoff ?? router.captureHandoff(for: model.jobID)
    }

    private var scanTitle: String {
        model.readyLocator != nil ? "Improve with a scan" : "Add a scan"
    }

    private var scanCaption: String {
        switch model.status {
        case .ready:
            return "Walk the roof with your iPhone's LiDAR to refine these measurements."
        case .failed:
            return "A ground-level LiDAR scan can finish this measurement when imagery falls short."
        default:
            return "Capture a LiDAR walk-around now to sharpen the result — no need to wait."
        }
    }
}

private struct TimelineRow: View {
    let item: StageTimelineItem
    let isLast: Bool
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(circleColor)
                    .frame(width: 22, height: 22)
                    .overlay(symbol)
                    .scaleEffect(item.state == .active && pulse && !reduceMotion ? 1.08 : 1)
                    .animation(
                        item.state == .active && !reduceMotion
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: pulse
                    )

                if !isLast {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 2, height: 38)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.RoofTrace.bodyMedium)
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.RoofTrace.label)
                        .foregroundStyle(Color.CC.ink75)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, isLast ? 0 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            pulse = item.state == .active
        }
        .onChange(of: item.state) { _, state in
            pulse = state == .active
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch item.state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.CC.chalk)
        case .active:
            Circle()
                .fill(Color.CC.chalk)
                .frame(width: 8, height: 8)
        case .pending:
            EmptyView()
        }
    }

    private var circleColor: Color {
        switch item.state {
        case .done:
            return Color.CC.blue
        case .active:
            return Color.CC.orangeHigh
        case .pending:
            return Color.CC.lineMid
        }
    }

    private var lineColor: Color {
        item.state == .done ? Color.CC.blue : Color.CC.lineMid
    }

    private var titleColor: Color {
        switch item.state {
        case .done, .active:
            return Color.CC.ink
        case .pending:
            return Color.CC.ink55
        }
    }
}
