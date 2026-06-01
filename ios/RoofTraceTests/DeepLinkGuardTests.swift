import XCTest
@testable import RoofTrace

/// Guards the deep-link credential-swap fix: capture now starts from an
/// immutable route handoff, leaving no mutable token-entry fields to mutate.
@MainActor
final class DeepLinkGuardTests: XCTestCase {
    private final class StubLocation: LocationProviding {
        var latestFix: LocationFix?
        private(set) var requestAuthorizationCount = 0
        func requestAuthorization() { requestAuthorizationCount += 1 }
        func acquireOriginFix(targetAccuracyM: Double, timeout: TimeInterval) async -> LocationFix? { nil }
    }

    // Two distinct valid base58 (32-char) tokens and two valid job UUIDs.
    private let tokenA = "1111111111111111111111111111111A"
    private let tokenB = "2222222222222222222222222222222B"
    private let jobA = "11111111-1111-4111-8111-111111111111"
    private let jobB = "22222222-2222-4222-8222-222222222222"

    private func makeVM(handoff: CaptureHandoff? = nil, location: StubLocation = StubLocation()) -> CaptureViewModel {
        CaptureViewModel(
            handoff: handoff ?? CaptureHandoff(token: tokenA, jobID: jobA),
            sensors: nil,
            location: location
        )
    }

    private func deepLink(token: String, jobID: String) -> URL {
        URL(string: "rooftrace://capture?token=\(token)&job_id=\(jobID)")!
    }

    func test_captureStartsAtSetupCheckWithHandoff() {
        let location = StubLocation()
        let vm = makeVM(location: location)

        XCTAssertEqual(vm.state, .setupCheck)
        XCTAssertEqual(vm.handoff.token, tokenA)
        XCTAssertEqual(vm.handoff.jobID, jobA)
        XCTAssertEqual(location.requestAuthorizationCount, 1)
    }

    func test_deepLinkBuildsNewRouteButCannotSwapActiveCaptureCredentials() {
        let vm = makeVM()
        let router = AppRouter()
        XCTAssertEqual(router.route(for: deepLink(token: tokenB, jobID: jobB)),
                       .capture(CaptureHandoff(token: tokenB, jobID: jobB)))

        XCTAssertEqual(vm.handoff.token, tokenA)
        XCTAssertEqual(vm.handoff.jobID, jobA)
    }
}
