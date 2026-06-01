import Foundation

protocol TokenStoring: Sendable {
    func loadToken() async throws -> String?
    func storeToken(_ token: String) async throws
    func clearToken() async throws
}
