import Foundation

struct CaptureHandoff: Hashable, Sendable {
    let token: String
    let jobID: String?
}

enum AppRoute: Hashable, Sendable {
    case jobDetail(id: String)
    case createJob
    case capture(CaptureHandoff)
    case report(jobID: String)
}
