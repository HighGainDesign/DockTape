// © 2026 High Gain Design. All rights reserved.

// Sources/HiDockKit/Summarization/KeychainHelper.swift
import Foundation
import Security

/// Minimal Keychain wrapper for storing API keys.
public enum KeychainHelper {

    /// Keychain service name for AI provider API keys.
    public static let aiService = "design.highgain.docktape.ai"

    public static func save(key: String, service: String, account: String) throws {
        let data = Data(key.utf8)

        // Delete existing item first (update = delete + add)
        delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    public enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Keychain save failed with status \(status)"
            }
        }
    }
}
