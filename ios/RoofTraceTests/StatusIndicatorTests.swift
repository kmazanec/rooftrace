import XCTest
@testable import RoofTrace

final class StatusIndicatorTests: XCTestCase {
    func testMapsEveryKnownStatusToATierAndLabel() {
        let cases: [(JobStatus, StatusIndicator.Kind, String)] = [
            (.pending, .working, "Queued"),
            (.processing(.resolvingAddress), .working, "Resolving address"),
            (.processing(.fetchingImagery), .working, "Fetching imagery"),
            (.processing(.fetchingLidar), .working, "Fetching LiDAR"),
            (.processing(.refiningOutline), .working, "Refining outline"),
            (.processing(.detectingFeatures), .working, "Detecting features"),
            (.processing(.fittingPlanes), .working, "Fitting planes"),
            (.ready(ReportLocator(jobID: "job-1", shareToken: nil)), .done, "Ready"),
            (.failed(reason: "boom"), .failed, "Failed")
        ]

        for (status, kind, label) in cases {
            let model = StatusIndicator.Model(status: status)
            XCTAssertEqual(model.kind, kind)
            XCTAssertEqual(model.label, label)
            XCTAssertFalse(model.systemImageName.isEmpty)
        }
    }

    func testUnknownStatusSurfacesAsFailedTier() {
        let model = StatusIndicator.Model(status: .unknown("paused"))

        XCTAssertEqual(model.kind, .failed)
        XCTAssertEqual(model.label, "Unknown")
    }
}
