import Foundation
import Security

/// Senha do usuário `deck`, uma por Deck. Só o Keychain a guarda; ela nunca vai para disco nem log.
enum Keychain {
    private static let service = "io.github.raphaeltorquat0.QuietDeck"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func password(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ password: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    /// Credenciais com mais de um campo ficam juntas num item só.
    static func decoded<T: Decodable>(_ type: T.Type, for account: String) -> T? {
        password(for: account).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    static func remove(for account: String) { SecItemDelete(query(account) as CFDictionary) }
}
