import Foundation
import Observation

enum StageTimelineState: Equatable, Sendable {
    case done
    case active
    case pending
}

struct StageTimelineItem: Identifiable, Equatable, Sendable {
    let stage: Stage
    let state: StageTimelineState
    let title: String
    let subtitle: String?

    var id: Stage { stage }
}

@Observable
@MainActor
final class StatusPollViewModel {
    var job: JobStatusResponse?
    private(set) var isPolling = false
    private(set) var transientMessage: String?

    let jobID: String
    private let api: any APIClientProtocol
    private let authStore: AuthStore
    private let clock: any PollClockProviding
    private let baseInterval: TimeInterval = 2
    private let maxInterval: TimeInterval = 15

    init(
        jobID: String,
        api: any APIClientProtocol,
        authStore: AuthStore,
        clock: any PollClockProviding = RealPollClock()
    ) {
        self.jobID = jobID
        self.api = api
        self.authStore = authStore
        self.clock = clock
    }

    var status: JobStatus {
        job?.status ?? .pending
    }

    var address: String {
        job?.address ?? "Job \(jobID)"
    }

    var readyLocator: ReportLocator? {
        if case .ready(let locator) = status {
            return locator
        }
        return nil
    }

    var failedReason: String? {
        if case .failed(let reason) = status {
            return reason
        }
        return nil
    }

    var shouldShowScanAction: Bool {
        readyLocator != nil
    }

    var progressFraction: Double {
        guard let activeIndex = activeStageIndex else {
            switch status {
            case .ready:
                return 1
            case .failed:
                return completedStageFraction
            case .pending, .unknown:
                return 0
            case .processing:
                return 0
            }
        }
        return Double(activeIndex + 1) / Double(Stage.allCases.count)
    }

    var timelineItems: [StageTimelineItem] {
        let activeIndex = activeStageIndex
        return Stage.allCases.enumerated().map { index, stage in
            let state: StageTimelineState
            switch status {
            case .ready:
                state = .done
            case .failed:
                if let activeIndex {
                    state = index < activeIndex ? .done : index == activeIndex ? .active : .pending
                } else {
                    state = .pending
                }
            case .pending, .unknown:
                state = index == 0 ? .active : .pending
            case .processing:
                if let activeIndex {
                    state = index < activeIndex ? .done : index == activeIndex ? .active : .pending
                } else {
                    state = .pending
                }
            }

            return StageTimelineItem(
                stage: stage,
                state: state,
                title: stage.title,
                subtitle: state == .active ? stage.subtitle : nil
            )
        }
    }

    func pollUntilTerminal() async {
        guard !isPolling else { return }
        isPolling = true
        transientMessage = nil
        defer { isPolling = false }

        var nextInterval = baseInterval

        while !Task.isCancelled {
            do {
                try Task.checkCancellation()
                let response = try await api.job(id: jobID)
                job = response
                transientMessage = nil
                nextInterval = baseInterval

                if response.status.isTerminal {
                    return
                }

                try await clock.sleep(for: baseInterval)
            } catch APIError.unauthorized {
                await authStore.handleUnauthorized()
                return
            } catch is CancellationError {
                return
            } catch {
                transientMessage = "Connection interrupted. We'll keep checking."
                do {
                    try await clock.sleep(for: nextInterval)
                } catch {
                    return
                }
                nextInterval = min(nextInterval * 2, maxInterval)
            }
        }
    }

    func retry() async {
        guard !isPolling else { return }
        transientMessage = nil
        await pollUntilTerminal()
    }

    private var activeStageIndex: Int? {
        switch status {
        case .pending:
            return 0
        case .processing(let stage):
            return Stage.allCases.firstIndex(of: stage)
        case .ready:
            return Stage.allCases.indices.last
        case .failed:
            if let job, case .failed = job.status {
                return Stage.allCases.indices.last
            }
            return nil
        case .unknown:
            return 0
        }
    }

    private var completedStageFraction: Double {
        guard let activeStageIndex else { return 0 }
        return Double(activeStageIndex) / Double(Stage.allCases.count)
    }
}

private extension JobStatus {
    var isTerminal: Bool {
        switch self {
        case .ready, .failed:
            return true
        case .pending, .processing, .unknown:
            return false
        }
    }
}

extension Stage {
    var title: String {
        switch self {
        case .resolvingAddress:
            return "Resolving address"
        case .fetchingImagery:
            return "Fetching imagery"
        case .fetchingLidar:
            return "Fetching LiDAR"
        case .refiningOutline:
            return "Refining outline"
        case .detectingFeatures:
            return "Detecting features"
        case .fittingPlanes:
            return "Fitting planes"
        }
    }

    var subtitle: String {
        switch self {
        case .resolvingAddress:
            return "Checking the property location before any roof work starts."
        case .fetchingImagery:
            return "Pulling the latest available overhead imagery."
        case .fetchingLidar:
            return "Looking for elevation data near this address."
        case .refiningOutline:
            return "Separating the roof outline from nearby structures."
        case .detectingFeatures:
            return "Finding ridges, valleys, edges, and roof features."
        case .fittingPlanes:
            return "Fitting roof planes so the final measurements are traceable."
        }
    }
}
