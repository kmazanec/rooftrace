import XCTest
@testable import RoofTrace

@MainActor
final class AppRouterTests: XCTestCase {
    func testPushAndPop() {
        let router = AppRouter()
        router.push(.createJob)
        XCTAssertEqual(router.path, [.createJob])
        router.pop()
        XCTAssertEqual(router.path, [])
    }

    func testDeepLinkRoutesToCapture() {
        let router = AppRouter()
        let url = URL(string: "rooftrace://capture?token=1111111111111111111111111111111A&job_id=11111111-1111-4111-8111-111111111111")!
        XCTAssertEqual(
            router.route(for: url),
            .capture(CaptureHandoff(token: "1111111111111111111111111111111A", jobID: "11111111-1111-4111-8111-111111111111"))
        )
    }

    func testLoggedOutDeepLinkStashesAndReplaysAfterAuth() {
        let router = AppRouter()
        let url = URL(string: "rooftrace://jobs/job-1/report")!

        router.handle(url: url, isAuthenticated: false)
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(router.stashedRoute, .report(jobID: "job-1"))

        let replayed = router.replayStashedRouteIfAuthenticated(true)
        XCTAssertEqual(replayed, .report(jobID: "job-1"))
        XCTAssertEqual(router.path, [.report(jobID: "job-1")])
        XCTAssertNil(router.stashedRoute)
    }

    func testUnauthorizedDuringReplayRestashesRoute() {
        let router = AppRouter()
        let route = AppRoute.jobDetail(id: "job-1")
        router.push(route)
        router.restash(route)
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(router.stashedRoute, route)
    }
}
