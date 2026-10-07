import Foundation
import Security

/// Generic-password items for this app. Readable after the first unlock: a VoIP push can wake the app
/// on a locked phone and it still needs the token to tell the Mac the call was answered.
enum Keychain {
    private static let service = "it.dnafactory.elio.phone"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func write(_ data: Data, account: String) {
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query(account) as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var q = query(account)
            q.merge(attrs) { $1 }
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
