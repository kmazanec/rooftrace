import Foundation
import Observation

@Observable
@MainActor
final class AppRouter {
    var path: [AppRoute] = []
    private(set) var stashedRoute: AppRoute?

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func reset() {
        path = []
    }

    @discardableResult
    func handle(url: URL, isAuthenticated: Bool) -> AppRoute? {
        guard let route = route(for: url) else { return nil }
        if isAuthenticated {
            push(route)
        } else {
            stashedRoute = route
        }
        return route
    }

    @discardableResult
    func replayStashedRouteIfAuthenticated(_ isAuthenticated: Bool) -> AppRoute? {
        guard isAuthenticated, let route = stashedRoute else { return nil }
        stashedRoute = nil
        push(route)
        return route
    }

    func restash(_ route: AppRoute) {
        path.removeAll { $0 == route }
        stashedRoute = route
    }

    func route(for url: URL) -> AppRoute? {
        guard url.scheme == "rooftrace" else { return nil }

        if let capture = TokenValidator.parseDeepLink(url) {
            return .capture(CaptureHandoff(token: capture.token, jobID: capture.jobID))
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let host = components.host ?? ""
        let pathParts = components.path
            .split(separator: "/")
            .map(String.init)
        let parts = ([host] + pathParts).filter { !$0.isEmpty }

        if parts == ["create-job"] || parts == ["jobs", "new"] {
            return .createJob
        }

        if parts.count == 2, parts[0] == "jobs" {
            return .jobDetail(id: parts[1])
        }

        if parts.count == 3, parts[0] == "jobs", parts[2] == "report" {
            return .report(jobID: parts[1])
        }

        if parts.count == 2, parts[0] == "reports" {
            return .report(jobID: parts[1])
        }

        if let jobID = components.queryItems?.first(where: { $0.name == "job_id" })?.value,
           parts == ["report"] {
            return .report(jobID: jobID)
        }

        return nil
    }
}
