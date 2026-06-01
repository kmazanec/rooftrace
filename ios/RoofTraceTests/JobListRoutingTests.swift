import XCTest
@testable import RoofTrace

final class JobListRoutingTests: XCTestCase {
    func testReadyJobsRouteToReport() {
        let status = JobStatus.ready(ReportLocator(jobID: "ready-job", shareToken: "share-1"))

        XCTAssertEqual(route(for: status, jobID: "fallback-job"), .report(jobID: "ready-job"))
    }

    func testNonReadyJobsRouteToStatus() {
        let statuses: [JobStatus] = [
            .pending,
            .processing(.resolvingAddress),
            .processing(.fetchingImagery),
            .processing(.fetchingLidar),
            .processing(.refiningOutline),
            .processing(.detectingFeatures),
            .processing(.fittingPlanes),
            .failed(reason: "Could not resolve address"),
            .unknown("paused")
        ]

        for status in statuses {
            XCTAssertEqual(route(for: status, jobID: "job-1"), .jobDetail(id: "job-1"))
        }
    }
}
