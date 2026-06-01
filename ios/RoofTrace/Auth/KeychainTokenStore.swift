import Foundation
import Security

enum KeychainTokenStoreError: Error, Equatable {
    case unhandledStatus(OSStatus)
    case invalidData
}

actor KeychainTokenStore: TokenStoring {
    private let service: String
    private let account: String

    init(service: String = "dev.biograph.rooftrace", account: String = "app-token") {
        self.service = service
        self.account = account
    }

    func loadToken() async throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainTokenStoreError.invalidData
        }
        return token
    }

    func storeToken(_ token: String) async throws {
        let data = Data(token.utf8)
        var query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainTokenStoreError.unhandledStatus(updateStatus)
        }
        query.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainTokenStoreError.unhandledStatus(addStatus)
        }
    }

    func clearToken() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
