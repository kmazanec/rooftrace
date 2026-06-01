import Foundation

enum Stage: String, CaseIterable, Equatable, Sendable {
    case resolvingAddress = "resolving_address"
    case fetchingImagery = "fetching_imagery"
    case fetchingLidar = "fetching_lidar"
    case refiningOutline = "refining_outline"
    case detectingFeatures = "detecting_features"
    case fittingPlanes = "fitting_planes"
}

struct ReportLocator: Equatable, Sendable {
    let jobID: String
    let shareToken: String?
}

enum JobStatus: Equatable, Sendable {
    case pending
    case processing(Stage)
    case ready(ReportLocator)
    case failed(reason: String)
    case unknown(String)

    init(rawValue: String, jobID: String, shareToken: String?, lastError: String?) {
        if rawValue == "pending" {
            self = .pending
        } else if let stage = Stage(rawValue: rawValue) {
            self = .processing(stage)
        } else if rawValue == "ready" {
            self = .ready(ReportLocator(jobID: jobID, shareToken: shareToken))
        } else if rawValue == "failed" {
            self = .failed(reason: lastError ?? "Measurement failed")
        } else {
            self = .unknown(rawValue)
        }
    }
}
