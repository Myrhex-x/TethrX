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

    /// Copy a token into the shared group. Deliberately NEVER deletes first: this runs
    /// on every launch, and a delete followed by a failed add would destroy the only
    /// copy of the pairing token and silently force the user to pair again.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Some OS versions want the team-prefixed group, some accept the bare app-group
        // identifier. Try both before giving up; a failure here costs the share
        // extension, never the app's own pairing.
        for group in [accessGroup, "group.com.tethrx.app"] {
            var query = base
            query[kSecAttrAccessGroup as String] = group

            var update = query
            update[kSecValueData as String] = Data(value.utf8)
            // A share or a notification reply can arrive while the phone is locked, so
            // the token has to be readable after the first unlock.
            update[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let added = SecItemAdd(update as CFDictionary, nil)
            if added == errSecSuccess { return true }
            if added == errSecDuplicateItem {
                let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8)]
                if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecSuccess { return true }
            }
        }
        return false
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
