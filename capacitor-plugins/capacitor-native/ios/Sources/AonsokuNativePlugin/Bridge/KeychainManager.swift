import Foundation
import Security

public struct ServerCredentials: Codable {
    public let serverUrl: String
    public let username: String
    public let password: String
    public let authType: String
    public let protocolVersion: String
    public let serverType: String
    public let fallbackUrl: String?

    public init(
        serverUrl: String,
        username: String,
        password: String,
        authType: String,
        protocolVersion: String,
        serverType: String,
        fallbackUrl: String?
    ) {
        self.serverUrl = serverUrl
        self.username = username
        self.password = password
        self.authType = authType
        self.protocolVersion = protocolVersion
        self.serverType = serverType
        self.fallbackUrl = fallbackUrl
    }
}

public final class KeychainManager {
    private static let service = "github.realtvop.aonsoku.credentials"
    private static let account = "server-credentials"

    public static func set(_ value: String, forKey key: String, service: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query = keychainQuery(forKey: key, service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem.merge(attributes) { _, new in new }
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    public static func get(_ key: String, service: String) -> String? {
        var query = keychainQuery(forKey: key, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ key: String, service: String) {
        let query = keychainQuery(forKey: key, service: service)
        SecItemDelete(query as CFDictionary)
    }

    public static func store(_ credentials: ServerCredentials) throws {
        let data = try JSONEncoder().encode(credentials)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var newItem = query
            newItem.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unableToStore(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unableToStore(status)
        }
    }

    public static func storeIfPossible(_ credentials: ServerCredentials) -> Bool {
        return (try? store(credentials)) != nil
    }

    public static func retrieve() -> ServerCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(ServerCredentials.self, from: data)
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func exists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private static func keychainQuery(
        forKey key: String,
        service: String
    ) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

public enum KeychainError: Error {
    case unableToStore(OSStatus)
}
