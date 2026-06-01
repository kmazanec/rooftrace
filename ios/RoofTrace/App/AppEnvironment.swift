import Foundation

struct AppEnvironment {
    let api: any APIClientProtocol
    let tokenStore: any TokenStoring
    let auth: AuthStore
    let router: AppRouter

    @MainActor
    static func live() -> AppEnvironment {
        let tokenStore = KeychainTokenStore()
        let api = APIClient(baseURL: AppConfig.backendURL, tokenStore: tokenStore)
        let router = AppRouter()
        let auth = AuthStore(api: api, tokenStore: tokenStore)
        return AppEnvironment(api: api, tokenStore: tokenStore, auth: auth, router: router)
    }
}
