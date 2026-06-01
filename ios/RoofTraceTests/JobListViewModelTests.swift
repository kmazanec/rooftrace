import XCTest
@testable import RoofTrace

@MainActor
final class JobListViewModelTests: XCTestCase {
    func testLoadOrdersJobsNewestFirst() async {
        let older = job(id: "older", createdAt: Date(timeIntervalSinceReferenceDate: 10))
        let newer = job(id: "newer", createdAt: Date(timeIntervalSinceReferenceDate: 20))
        let api = FakeAPIClient(result: .success(JobsResponse(jobs: [older, newer])))
        let model = JobListViewModel(api: api, authStore: authStore())

        await model.load()

        XCTAssertEqual(model.state, .loaded([newer, older]))
        XCTAssertEqual(api.sentPaths, ["/api/v1/jobs"])
    }

    func testEmptyLoadProducesLoadedEmptyState() async {
        let api = FakeAPIClient(result: .success(JobsResponse(jobs: [])))
        let model = JobListViewModel(api: api, authStore: authStore())

        await model.load()

        XCTAssertEqual(model.state, .loaded([]))
    }

    func testErrorKeepsStaleRows() async {
        let stale = job(id: "stale", createdAt: Date(timeIntervalSinceReferenceDate: 10))
        let api = FakeAPIClient(results: [
            .success(JobsResponse(jobs: [stale])),
            .failure(APIError.transport)
        ])
        let model = JobListViewModel(api: api, authStore: authStore())

        await model.load()
        await model.refresh()

        XCTAssertEqual(model.state, .error(message: "Couldn't load jobs.", stale: [stale]))
    }

    func testRefreshSuccessReplacesRows() async {
        let first = job(id: "first", createdAt: Date(timeIntervalSinceReferenceDate: 10))
        let replacement = job(id: "replacement", createdAt: Date(timeIntervalSinceReferenceDate: 30))
        let api = FakeAPIClient(results: [
            .success(JobsResponse(jobs: [first])),
            .success(JobsResponse(jobs: [replacement]))
        ])
        let model = JobListViewModel(api: api, authStore: authStore())

        await model.load()
        await model.refresh()

        XCTAssertEqual(model.state, .loaded([replacement]))
    }

    func testUnauthorizedDelegatesToAuthStore() async {
        let tokenStore = FakeTokenStore(token: "app-token")
        let auth = AuthStore(api: FakeAPIClient(result: .failure(APIError.unauthorized)), tokenStore: tokenStore)
        await auth.bootstrap()
        XCTAssertTrue(auth.isAuthenticated)

        let model = JobListViewModel(
            api: FakeAPIClient(result: .failure(APIError.unauthorized)),
            authStore: auth
        )

        await model.load()

        XCTAssertFalse(auth.isAuthenticated)
        let snapshot = await tokenStore.snapshot()
        XCTAssertNil(snapshot.token)
        XCTAssertEqual(snapshot.clearCount, 1)
    }

    private func authStore() -> AuthStore {
        AuthStore(
            api: FakeAPIClient(result: .success(SessionResponse(appToken: "token", expiresAt: Date()))),
            tokenStore: FakeTokenStore()
        )
    }

    private func job(
        id: String,
        status: JobStatus = .pending,
        ready: Bool = false,
        totalAreaSqFt: Double? = nil,
        createdAt: Date
    ) -> JobSummary {
        JobSummary(
            id: id,
            address: "\(id) Main St",
            status: status,
            ready: ready,
            totalAreaSqFt: totalAreaSqFt,
            shareToken: nil,
            createdAt: createdAt
        )
    }
}
