import Foundation
import Security

/// Tight wrapper over `SecItem*` for storing the Curvy invite bundle
/// (PAT + room key + repo coordinates as one JSON blob).
///
/// All entries are scoped to the service identifier `dev.kumamaki.Curvy`
/// and use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — they
/// survive reboots, do not sync to iCloud, and are unreadable while the
/// device is locked at a cold boot.
///
/// Today there's exactly one account (`Account.invite`); the enum is
/// kept open so future state can be added cleanly.
struct KeychainStore: Sendable {
    enum Account {
        /// JSON-encoded `Invite` (token + room key + repo coordinates).
        /// Single atomic blob so onboarding can't half-succeed.
        static let invite = "invite.bundle"
    }

    enum KeychainError: Error, CustomStringConvertible {
        case status(OSStatus)
        case decodingFailed

        var description: String {
            switch self {
            case .status(let s): "Keychain status \(s)"
            case .decodingFailed: "Keychain value could not be decoded"
            }
        }
    }

    private let service: String

    init(service: String = "dev.kumamaki.Curvy") {
        self.service = service
    }

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.decodingFailed }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    func write(account: String, value: Data) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.status(addStatus)
            }
        default:
            throw KeychainError.status(updateStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

extension KeychainStore {
    func readString(account: String) throws -> String? {
        guard let data = try read(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeString(account: String, value: String) throws {
        try write(account: account, value: Data(value.utf8))
    }
}
