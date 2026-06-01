import Foundation
import Observation

@Observable
@MainActor
final class CreateJobViewModel {
    var address = ""
    private(set) var typeaheadState: TypeaheadState = .tooShort
    private(set) var errorMessage: String?
    private(set) var isSubmitting = false

    private let api: any APIClientProtocol
    private let authStore: AuthStore
    private let router: AppRouter
    private let addressCompleter: any AddressCompleting
    private let locationResolver: any LocationResolving
    private var searchGeneration = 0
    private let minQueryLength = 3

    init(
        api: any APIClientProtocol,
        authStore: AuthStore,
        router: AppRouter,
        addressCompleter: any AddressCompleting,
        locationResolver: any LocationResolving
    ) {
        self.api = api
        self.authStore = authStore
        self.router = router
        self.addressCompleter = addressCompleter
        self.locationResolver = locationResolver
    }

    var canSubmit: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    func searchAddress(_ query: String) async {
        address = query
        errorMessage = nil
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minQueryLength else {
            typeaheadState = .tooShort
            return
        }

        typeaheadState = .searching
        do {
            let suggestions = try await addressCompleter.suggestions(for: trimmed)
            guard generation == searchGeneration else { return }
            typeaheadState = suggestions.isEmpty ? .noMatches : .results(suggestions)
        } catch {
            guard generation == searchGeneration else { return }
            typeaheadState = .noMatches
        }
    }

    func select(_ suggestion: AddressSuggestion) {
        address = suggestion.displayAddress
        typeaheadState = .results([suggestion])
        errorMessage = nil
    }

    func useCurrentLocation() async {
        errorMessage = nil
        let permission = await locationResolver.permission
        let resolvedPermission = permission == .notDetermined
            ? await locationResolver.requestPermission()
            : permission

        guard resolvedPermission == .authorized else {
            errorMessage = "Location permission is off. Enable it in Settings or type the address."
            return
        }

        do {
            address = try await locationResolver.reverseGeocodeCurrentLocation()
            await searchAddress(address)
        } catch {
            errorMessage = "We could not turn your location into an address. Type it instead."
        }
    }

    func submit() async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let response = try await api.createJob(address: trimmed)
            let handoff = CaptureHandoff(token: response.captureToken, jobID: response.jobId)
            router.store(handoff, for: response.jobId)
            router.push(.jobDetail(id: response.jobId))
        } catch APIError.unauthorized {
            await authStore.handleUnauthorized()
        } catch {
            errorMessage = "Could not start this measurement. Check the address and try again."
        }
    }
}
