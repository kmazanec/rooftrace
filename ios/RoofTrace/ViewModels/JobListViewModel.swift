import Foundation
import Observation

enum LoadState: Equatable {
    case idle
    case loading
    case loaded([JobSummary])
    case error(message: String, stale: [JobSummary])

    var rows: [JobSummary] {
        switch self {
        case .idle, .loading:
            return []
        case .loaded(let jobs):
            return jobs
        case .error(_, let stale):
            return stale
        }
    }
}

@Observable
@MainActor
final class JobListViewModel {
    private let api: any APIClientProtocol
    private let authStore: AuthStore
    private(set) var state: LoadState = .idle

    init(api: any APIClientProtocol, authStore: AuthStore) {
        self.api = api
        self.authStore = authStore
    }

    func load() async {
        await fetch(showLoadingWhenEmpty: true)
    }

    func refresh() async {
        await fetch(showLoadingWhenEmpty: false)
    }

    private func fetch(showLoadingWhenEmpty: Bool) async {
        let stale = state.rows
        if showLoadingWhenEmpty, stale.isEmpty {
            state = .loading
        }

        do {
            let jobs = try await api.jobs()
                .sorted { $0.createdAt > $1.createdAt }
            state = .loaded(jobs)
        } catch APIError.unauthorized {
            await authStore.handleUnauthorized()
            state = .error(message: "Couldn't load jobs.", stale: stale)
        } catch {
            state = .error(message: "Couldn't load jobs.", stale: stale)
        }
    }
}
