import XCTest
@testable import RoofTrace

@MainActor
final class CreateJobViewModelTests: XCTestCase {
    func testCanSubmitRequiresAddressAndNotSubmitting() {
        let model = makeModel()

        XCTAssertFalse(model.canSubmit)
        model.address = "  123 Main St  "
        XCTAssertTrue(model.canSubmit)
    }

    func testTypeaheadTransitionsAndSelection() async {
        let suggestion = AddressSuggestion(id: "one", title: "123 Main St", subtitle: "Lincoln, NE")
        let completer = FakeAddressCompleter(results: [.success([suggestion])])
        let model = makeModel(completer: completer)

        await model.searchAddress("12")
        XCTAssertEqual(model.typeaheadState, .tooShort)

        await model.searchAddress("123")
        XCTAssertEqual(model.typeaheadState, .results([suggestion]))

        model.select(suggestion)
        XCTAssertEqual(model.address, "123 Main St, Lincoln, NE")
    }

    func testTypeaheadDropsStaleResults() async {
        let slow = FakeAddressCompleter(
            responses: [
                "old": .delayed(
                    .success([AddressSuggestion(id: "old", title: "Old", subtitle: "")]),
                    nanoseconds: 20_000_000
                ),
                "new": .success([AddressSuggestion(id: "new", title: "New", subtitle: "")])
            ]
        )
        let model = makeModel(completer: slow)

        async let first: Void = model.searchAddress("old")
        try? await Task.sleep(nanoseconds: 1_000_000)
        async let second: Void = model.searchAddress("new")
        _ = await (first, second)

        XCTAssertEqual(model.typeaheadState, .results([AddressSuggestion(id: "new", title: "New", subtitle: "")]))
    }

    func testUseCurrentLocationPermissionDeniedShowsInlineError() async {
        let model = makeModel(location: FakeLocationResolver(permission: .denied, address: nil))

        await model.useCurrentLocation()

        XCTAssertEqual(model.errorMessage, "Location permission is off. Enable it in Settings or type the address.")
        XCTAssertEqual(model.address, "")
    }

    func testUseCurrentLocationMapsAddressIntoField() async {
        let model = makeModel(
            completer: FakeAddressCompleter(results: [.success([])]),
            location: FakeLocationResolver(permission: .authorized, address: "500 Pine St")
        )

        await model.useCurrentLocation()

        XCTAssertEqual(model.address, "500 Pine St")
        XCTAssertEqual(model.typeaheadState, .noMatches)
    }

    func testSubmitCreatesJobStoresHandoffAndRoutesToStatus() async {
        let response = CreateJobResponse(
            jobId: "job-1",
            captureToken: "capture-token",
            captureTokenExpiresAt: Date()
        )
        let api = FakeAPIClient(result: .success(response))
        let router = AppRouter()
        let model = makeModel(api: api, router: router)
        model.address = "123 Main St"

        await model.submit()

        XCTAssertEqual(api.sentPaths, ["/api/v1/jobs"])
        XCTAssertEqual(router.path, [.jobDetail(id: "job-1")])
        XCTAssertEqual(router.captureHandoff(for: "job-1"), CaptureHandoff(token: "capture-token", jobID: "job-1"))
        XCTAssertNil(model.errorMessage)
    }

    func testSubmitErrorKeepsEnteredAddress() async {
        let model = makeModel(api: FakeAPIClient(result: .failure(APIError.server(422))))
        model.address = "123 Main St"

        await model.submit()

        XCTAssertEqual(model.address, "123 Main St")
        XCTAssertEqual(model.errorMessage, "Could not start this measurement. Check the address and try again.")
    }

    private func makeModel(
        api: FakeAPIClient = FakeAPIClient(result: .failure(APIError.transport)),
        auth: AuthStore? = nil,
        router: AppRouter? = nil,
        completer: FakeAddressCompleter = FakeAddressCompleter(results: []),
        location: FakeLocationResolver = FakeLocationResolver(permission: .authorized, address: "123 Main St")
    ) -> CreateJobViewModel {
        CreateJobViewModel(
            api: api,
            authStore: auth ?? AuthStore(api: FakeAPIClient(result: .failure(APIError.transport)), tokenStore: FakeTokenStore()),
            router: router ?? AppRouter(),
            addressCompleter: completer,
            locationResolver: location
        )
    }
}

actor FakeAddressCompleter: AddressCompleting {
    enum Response: Sendable {
        case delayed(Result<[AddressSuggestion], Error>, nanoseconds: UInt64)
        case immediate(Result<[AddressSuggestion], Error>)

        static func success(_ suggestions: [AddressSuggestion]) -> Response {
            .immediate(.success(suggestions))
        }
    }

    private var results: [Result<[AddressSuggestion], Error>]
    private let responses: [String: Response]

    init(results: [Result<[AddressSuggestion], Error>]) {
        self.results = results
        responses = [:]
    }

    init(responses: [String: Response]) {
        results = []
        self.responses = responses
    }

    func suggestions(for query: String) async throws -> [AddressSuggestion] {
        if let response = responses[query] {
            switch response {
            case .delayed(let result, let nanoseconds):
                try? await Task.sleep(nanoseconds: nanoseconds)
                return try result.get()
            case .immediate(let result):
                return try result.get()
            }
        }

        let result = results.isEmpty ? .success([]) : results.removeFirst()
        switch result {
        case .success(let suggestions):
            return suggestions
        case .failure(let error):
            throw error
        }
    }
}

struct FakeLocationResolver: LocationResolving {
    let startingPermission: LocationPermission
    let address: String?

    init(permission: LocationPermission, address: String?) {
        startingPermission = permission
        self.address = address
    }

    var permission: LocationPermission {
        get async { startingPermission }
    }

    func requestPermission() async -> LocationPermission {
        startingPermission
    }

    func reverseGeocodeCurrentLocation() async throws -> String {
        guard let address else { throw LocationResolverError.unavailable }
        return address
    }
}
