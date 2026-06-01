import Foundation

struct CaptureHandoff: Hashable, Sendable {
    let token: String
    let jobID: String?

    var requiredJobID: String {
        guard let jobID else {
            preconditionFailure("CaptureHandoff requires a jobID before upload")
        }
        return jobID
    }
}

enum AppRoute: Hashable, Sendable {
    case jobDetail(id: String)
    case createJob
    case capture(CaptureHandoff)
    case report(jobID: String)
}
