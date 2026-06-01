import Foundation
import Observation

enum AuthStatus: Equatable {
    case unauthenticated
    case authenticated
}

@Observable
@MainActor
final class AuthStore {
    private let api: any APIClientProtocol
    private let tokenStore: any TokenStoring
    private(set) var status: AuthStatus = .unauthenticated
    private(set) var isBootstrapping = false

    var isAuthenticated: Bool {
        status == .authenticated
    }

    init(api: any APIClientProtocol, tokenStore: any TokenStoring) {
        self.api = api
        self.tokenStore = tokenStore
    }

    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        do {
            status = try await tokenStore.loadToken() == nil ? .unauthenticated : .authenticated
        } catch {
            status = .unauthenticated
        }
    }

    @discardableResult
    func signIn(username: String, password: String) async throws -> SessionResponse {
        let response = try await api.createSession(username: username, password: password)
        try await tokenStore.storeToken(response.appToken)
        status = .authenticated
        return response
    }

    func handleUnauthorized() async {
        guard status == .authenticated else { return }
        status = .unauthenticated
        try? await tokenStore.clearToken()
    }
}
