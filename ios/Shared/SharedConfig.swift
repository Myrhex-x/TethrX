import Foundation
import Security

/// What the share extension needs to know about the paired computer.
///
/// An extension is a separate process with its own container, so it cannot read the
/// app's own UserDefaults or Keychain. The app publishes the non-secret details into
/// the shared App Group and keeps the pairing token in a shared Keychain access
/// group — the token stays in the Keychain (encrypted, hardware-backed, unreadable
/// while the device is locked) rather than being copied into a plist beside it.
enum SharedConfig {
    static let appGroup = "group.com.tethrx.app"
    private static let bridgesKey = "shared.bridges"
    private static let activeKey = "shared.activeBridgeId"

    /// A paired computer, minus its token.
    struct Bridge: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var address: String
        var pin: String?
        var tokenAccount: String { "bridge.token." + id }
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Called by the app whenever its bridge list changes.
    static func publish(bridges: [Bridge], activeId: String?) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(bridges) {
            defaults.set(data, forKey: bridgesKey)
        }
        defaults.set(activeId, forKey: activeKey)
    }

    static func bridges() -> [Bridge] {
        guard let data = defaults?.data(forKey: bridgesKey),
              let list = try? JSONDecoder().decode([Bridge].self, from: data) else { return [] }
        return list
    }

    static func activeBridge() -> Bridge? {
        let list = bridges()
        if let id = defaults?.string(forKey: activeKey), let match = list.first(where: { $0.id == id }) {
            return match
        }
        return list.first
    }

    /// The pairing token for a bridge, from the shared Keychain group.
    static func token(for bridge: Bridge) -> String? {
        SharedKeychain.load(account: bridge.tokenAccount)
    }
}

/// Keychain access scoped to the group both the app and its extensions can reach.
enum SharedKeychain {
    static let service = "com.tethrx.app"

    /// Keychain access groups are matched as EXACT strings against the entitlement,
    /// which is `$(AppIdentifierPrefix)group.com.tethrx.app` — the team prefix is
    /// part of the name. Saving under the bare "group.com.tethrx.app" stores an item
    /// nothing is entitled to read: the app still works (its own unscoped reads find
    /// the older copy) while the extension silently sees an empty keychain and claims
    /// the phone was never paired. The prefix must be there.
    static let teamPrefix = "KKRU446268."          // DEVELOPMENT_TEAM, as in the entitlements
    static let accessGroup = teamPrefix + "group.com.tethrx.app"

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // clears any copy, in any entitled group
        guard !value.isEmpty else { return false }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // A share or a notification reply can arrive while the phone is locked, so the
        // token has to be readable after the first unlock.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        add[kSecAttrAccessGroup as String] = accessGroup
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return true }

        // Some OS versions accept an app-group identifier as a keychain group without
        // the team prefix. Try that rather than leaving the token unshared.
        add[kSecAttrAccessGroup as String] = "group.com.tethrx.app"
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return true }

        // Neither form was allowed: keep the token working for the app itself, even
        // though the share extension won't see it.
        add.removeValue(forKey: kSecAttrAccessGroup as String)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
