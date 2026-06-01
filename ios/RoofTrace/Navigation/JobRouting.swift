import Foundation

func route(for job: JobSummary) -> AppRoute {
    route(for: job.status, jobID: job.id)
}

func route(for status: JobStatus, jobID: String) -> AppRoute {
    switch status {
    case .ready(let locator):
        return .report(jobID: locator.jobID)
    case .pending,
         .processing,
         .failed,
         .unknown:
        return .jobDetail(id: jobID)
    }
}
