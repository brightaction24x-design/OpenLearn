import Foundation
import Security

enum KeychainStore {
    private static let service = "com.openlearn.app"

    enum ReadResult {
        case found(String)
        case missing              // nothing saved
        case failed(OSStatus)     // saved, but macOS wouldn't hand it over
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Saves a value. Passing an empty string deletes the entry.
    /// Returns false if macOS refused.
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let query = baseQuery(account)

        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(value.utf8)
        var item = query
        item[kSecValueData as String] = data

        // Update in place first, so the entry keeps any "Always Allow" you gave it
        let changes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)

        if status == errSecItemNotFound {
            status = SecItemAdd(item as CFDictionary, nil)
        } else if status != errSecSuccess {
            // The old entry may belong to an earlier build of the app: replace it
            SecItemDelete(query as CFDictionary)
            status = SecItemAdd(item as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func read(_ account: String) -> ReadResult {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data else { return .failed(status) }
        return .found(String(decoding: data, as: UTF8.self))
    }

    /// Reads a value. Returns "" if it can't be read.
    static func get(_ account: String) -> String {
        if case .found(let value) = read(account) { return value }
        return ""
    }
}
