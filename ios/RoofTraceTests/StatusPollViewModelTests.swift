import XCTest
@testable import RoofTrace

@MainActor
final class StatusPollViewModelTests: XCTestCase {
    func testPollingAdvancesToReadyAndStops() async {
        let api = FakeAPIClient(results: [
            .success(job(status: .processing(.resolvingAddress))),
            .success(job(status: .processing(.fetchingImagery))),
            .success(job(status: .ready(ReportLocator(jobID: "job-1", shareToken: "share-1")), ready: true))
        ])
        let clock = ManualClock()
        let model = makeModel(api: api, clock: clock)

        let task = Task { await model.pollUntilTerminal() }
        await clock.waitForSleepCount(1)
        await clock.resumeNext()
        await clock.waitForSleepCount(2)
        await clock.resumeNext()
        await task.value

        XCTAssertEqual(api.sentPaths, [
            "/api/v1/jobs/job-1",
            "/api/v1/jobs/job-1",
            "/api/v1/jobs/job-1"
        ])
        XCTAssertEqual(model.readyLocator, ReportLocator(jobID: "job-1", shareToken: "share-1"))
        XCTAssertFalse(model.isPolling)
        let intervals = await clock.snapshot()
        XCTAssertEqual(intervals, [2, 2])
    }

    func testCancellationStopsLoop() async {
        let api = FakeAPIClient(results: [
            .success(job(status: .processing(.resolvingAddress))),
            .success(job(status: .processing(.fetchingImagery)))
        ])
        let clock = ManualClock()
        let model = makeModel(api: api, clock: clock)

        let task = Task { await model.pollUntilTerminal() }
        await clock.waitForSleepCount(1)
        task.cancel()
        await clock.resumeNext()
        await task.value

        XCTAssertEqual(api.sentPaths, ["/api/v1/jobs/job-1"])
        XCTAssertFalse(model.isPolling)
    }

    func testTransientErrorsBackOffAndResetAfterSuccess() async {
        let api = FakeAPIClient(results: [
            .failure(APIError.transport),
            .failure(APIError.server(503)),
            .success(job(status: .processing(.fittingPlanes))),
            .success(job(status: .ready(ReportLocator(jobID: "job-1", shareToken: nil)), ready: true))
        ])
        let clock = ManualClock()
        let model = makeModel(api: api, clock: clock)

        let task = Task { await model.pollUntilTerminal() }
        await clock.waitForSleepCount(1)
        XCTAssertEqual(model.transientMessage, "Connection interrupted. We'll keep checking.")
        await clock.resumeNext()

        await clock.waitForSleepCount(2)
        await clock.resumeNext()

        await clock.waitForSleepCount(3)
        XCTAssertNil(model.transientMessage)
        await clock.resumeNext()
        await task.value

        let intervals = await clock.snapshot()
        XCTAssertEqual(intervals, [2, 4, 2])
        XCTAssertNotNil(model.readyLocator)
    }

    func testFailedStatusSurfacesReasonAndStops() async {
        let api = FakeAPIClient(result: .success(job(status: .failed(reason: "Imagery was unavailable"))))
        let clock = ManualClock()
        let model = makeModel(api: api, clock: clock)

        await model.pollUntilTerminal()

        XCTAssertEqual(model.failedReason, "Imagery was unavailable")
        let intervals = await clock.snapshot()
        XCTAssertEqual(intervals, [])
        XCTAssertEqual(model.timelineItems.last?.state, .active)
    }

    func testUnauthorizedDelegatesToAuthStoreAndStops() async {
        let tokenStore = FakeTokenStore(token: "app-token")
        let auth = AuthStore(api: FakeAPIClient(result: .failure(APIError.transport)), tokenStore: tokenStore)
        await auth.bootstrap()
        XCTAssertTrue(auth.isAuthenticated)
        let model = makeModel(
            api: FakeAPIClient(result: .failure(APIError.unauthorized)),
            auth: auth,
            clock: ManualClock()
        )

        await model.pollUntilTerminal()

        XCTAssertFalse(auth.isAuthenticated)
        let snapshot = await tokenStore.snapshot()
        XCTAssertNil(snapshot.token)
        XCTAssertEqual(snapshot.clearCount, 1)
    }

    func testTimelineMapsEachProcessingStage() {
        for stage in Stage.allCases {
            let model = makeModel(api: FakeAPIClient(result: .success(job(status: .processing(stage)))))
            model.job = job(status: .processing(stage))

            let items = model.timelineItems
            let activeIndex = Stage.allCases.firstIndex(of: stage)!

            XCTAssertEqual(items[activeIndex].state, .active)
            XCTAssertEqual(items.prefix(activeIndex).map(\.state), Array(repeating: .done, count: activeIndex))
            XCTAssertEqual(
                items.suffix(from: activeIndex + 1).map(\.state),
                Array(repeating: .pending, count: Stage.allCases.count - activeIndex - 1)
            )
        }
    }

    private func makeModel(
        api: FakeAPIClient,
        auth: AuthStore? = nil,
        clock: any PollClockProviding = ManualClock()
    ) -> StatusPollViewModel {
        StatusPollViewModel(
            jobID: "job-1",
            api: api,
            authStore: auth ?? AuthStore(api: FakeAPIClient(result: .failure(APIError.transport)), tokenStore: FakeTokenStore()),
            clock: clock
        )
    }

    private func job(
        status: JobStatus,
        ready: Bool = false,
        lastError: String? = nil
    ) -> JobStatusResponse {
        JobStatusResponse(
            id: "job-1",
            address: "123 Main St",
            status: status,
            lastError: lastError,
            ready: ready,
            shareToken: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 10)
        )
    }
}

final class ManualClock: PollClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [TimeInterval] = []
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func sleep(for interval: TimeInterval) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                intervals.append(interval)
                continuations.append(continuation)
            }
        }
        try Task.checkCancellation()
    }

    func resumeNext() async {
        let continuation = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        continuation?.resume()
    }

    func snapshot() async -> [TimeInterval] {
        lock.withLock { intervals }
    }

    func waitForSleepCount(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(1)
        while await snapshot().count < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let actual = await snapshot().count
        XCTAssertGreaterThanOrEqual(actual, count, file: file, line: line)
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}
