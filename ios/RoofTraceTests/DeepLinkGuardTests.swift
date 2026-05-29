import XCTest
@testable import RoofTrace

/// Guards the deep-link credential-swap fix: a `rooftrace://capture?...` link is
/// only honored while the flow is on the token-entry screen. A link arriving
/// after capture has started must NOT mutate the credentials (it could otherwise
/// redirect the completed bundle to an attacker's job).
@MainActor
final class DeepLinkGuardTests: XCTestCase {
    private final class StubLocation: LocationProviding {
        var latestFix: LocationFix?
        func requestAuthorization() {}
        func acquireOriginFix(targetAccuracyM: Double, timeout: TimeInterval) async -> LocationFix? { nil }
    }

    // Two distinct valid base58 (32-char) tokens and two valid job UUIDs.
    private let tokenA = "1111111111111111111111111111111A"
    private let tokenB = "2222222222222222222222222222222B"
    private let jobA = "11111111-1111-4111-8111-111111111111"
    private let jobB = "22222222-2222-4222-8222-222222222222"

    private func makeVM() -> CaptureViewModel {
        CaptureViewModel(sensors: nil, location: StubLocation())
    }

    private func deepLink(token: String, jobID: String) -> URL {
        URL(string: "rooftrace://capture?token=\(token)&job_id=\(jobID)")!
    }

    func test_deepLink_applied_in_tokenEntry() {
        let vm = makeVM()
        XCTAssertEqual(vm.state, .tokenEntry)
        vm.applyDeepLink(deepLink(token: tokenA, jobID: jobA))
        XCTAssertEqual(vm.tokenInput, tokenA)
        XCTAssertEqual(vm.jobIDInput, jobA)
    }

    func test_deepLink_ignored_once_past_tokenEntry() {
        let vm = makeVM()
        vm.applyDeepLink(deepLink(token: tokenA, jobID: jobA))
        // Move past token entry (advances to .setupCheck, snapshots creds).
        vm.startSetupCheck()
        XCTAssertNotEqual(vm.state, .tokenEntry)

        // A malicious link arriving mid-flow must be ignored: inputs unchanged.
        vm.applyDeepLink(deepLink(token: tokenB, jobID: jobB))
        XCTAssertEqual(vm.tokenInput, tokenA)
        XCTAssertEqual(vm.jobIDInput, jobA)
    }
}
