import Foundation
import Security

/// The keys, tokens, and client secrets the owner types in Status → Connections.
/// They live only in this iPhone's Keychain: available after the first unlock, never synced, never backed up to another device.
/// They never go to UserDefaults, the App Group, logs, or the quest context.
nonisolated enum SecretStore {
    static let service = "com.angelmorales.thesystem.connections"

    enum Item: String, CaseIterable {
        case hevyApiKey
        case stravaClientId
        case stravaClientSecret
        /// JSON `{"access_token", "refresh_token", "expires_at"}` from the Strava token endpoint.
        case stravaTokens
        case whoopClientId
        case whoopClientSecret
        /// JSON `{"access_token", "refresh_token", "expires_at"}`. WHOOP rotates the refresh token on each use.
        case whoopTokens
        /// JSON `{"access_token", "refresh_token", "expires_at"}` from WHOOP's Cognito sign-in, for the private stress API.
        case whoopPrivateTokens
        case mercuryToken
        case anthropicApiKey
    }

    /// The query that names one item. Pure, so the self-check can read it.
    static func query(_ item: Item) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    static func read(_ item: Item) -> String? {
        var query = query(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func has(_ item: Item) -> Bool { read(item) != nil }

    /// Saves the value in place of the old one. An empty value deletes the item.
    @discardableResult
    static func save(_ value: String, for item: Item) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        delete(item)
        guard !trimmed.isEmpty else { return true }
        var attributes = query(item)
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ item: Item) {
        SecItemDelete(query(item) as CFDictionary)
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    /// Checks the query shape only. It does not read or write the Keychain.
    static func check() -> [String] {
        var errors: [String] = []
        let query = query(.anthropicApiKey)
        if query[kSecClass as String] as? String != kSecClassGenericPassword as String
            || query[kSecAttrService as String] as? String != service
            || query[kSecAttrAccount as String] as? String != "anthropicApiKey" {
            errors.append("a secret should be a generic password under the connections service")
        }
        if query[kSecValueData as String] != nil || query[kSecAttrSynchronizable as String] != nil {
            errors.append("the item query must not carry the value or sync the item")
        }
        if Set(Item.allCases.map(\.rawValue)).count != Item.allCases.count {
            errors.append("every secret needs its own Keychain account")
        }
        return errors
    }
}
