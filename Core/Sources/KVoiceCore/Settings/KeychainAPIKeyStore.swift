import Foundation
import Security

/// Keychain-backed API key storage — plan §2 Phase 3's "`kSecClassGenericPassword`
/// wrapper in `Core` (Security framework is UI-free)".
///
/// One generic-password item, identified by (`service`, `account`). `set`
/// updates in place when the item exists rather than delete-then-add, so the
/// item's ACL — and therefore the user's "always allow" decision — survives a
/// key rotation.
///
/// ## Testing
///
/// There are no unit tests that call `SecItemAdd` here, deliberately. A test
/// binary is unsigned and has no stable keychain identity, so a real read or
/// write can surface a system authorization dialog on a developer's machine or
/// fail with `errSecMissingEntitlement` in a headless run — either way, a test
/// that is not a test. What *is* tested is everything decidable without the
/// daemon: query construction (``baseQuery(service:account:)``) and the
/// `OSStatus` → ``KeychainError`` mapping. The behavior that depends on this
/// type is covered through ``APIKeyStore`` with ``InMemoryAPIKeyStore``.
public struct KeychainAPIKeyStore: APIKeyStore {

    /// Default keychain service. One item per app, not per user account.
    public static let defaultService = "ai.kizaki.KVoice"

    /// Default account name inside that service.
    public static let defaultAccount = "assemblyai-api-key"

    public let service: String
    public let account: String

    public init(
        service: String = KeychainAPIKeyStore.defaultService,
        account: String = KeychainAPIKeyStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    // MARK: - APIKeyStore

    public func apiKey() throws -> String? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.unexpectedItemFormat
            }
            guard let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedItemFormat
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    public func setAPIKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.unexpectedItemFormat
        }

        let query = Self.baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            // The key is only ever needed while the user is at the machine,
            // and it must not travel to another device in a backup.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        default:
            throw KeychainError.status(updateStatus)
        }
    }

    public func deleteAPIKey() throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        // Deleting something that was never there is the caller's desired end
        // state, not a failure.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    // MARK: - Query construction (unit-tested)

    /// The attributes that identify our one item. Every operation starts here,
    /// so a lookup can never disagree with a write about what it addresses.
    static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Keychain failures, with the raw `OSStatus` preserved for diagnosis.
public enum KeychainError: Error, Sendable, Equatable {
    /// A non-success `OSStatus` from the Security framework.
    case status(OSStatus)
    /// The item existed but did not hold UTF-8 text.
    case unexpectedItemFormat

    /// Whether the failure means "the user (or the system) said no" rather
    /// than "something is broken" — the cases where the right response is to
    /// ask for the key again instead of showing a bug report.
    public var isAccessDenied: Bool {
        guard case .status(let status) = self else { return false }
        return status == errSecUserCanceled
            || status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
            || status == errSecInteractionRequired
    }
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status)\(message.map { ": \($0)" } ?? ".")"
        case .unexpectedItemFormat:
            return "The Keychain item exists but does not contain readable text."
        }
    }
}
