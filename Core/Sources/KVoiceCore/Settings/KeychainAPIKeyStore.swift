import Foundation
import Security

/// Keychain-backed API key storage — plan §2 Phase 3's "`kSecClassGenericPassword`
/// wrapper in `Core` (Security framework is UI-free)".
///
/// One generic-password item, identified by (`service`, `account`).
///
/// ## Why saving replaces the item instead of updating it
///
/// Every read of a login-keychain item is an authorization check against that
/// item's ACL, and a check that does not pass is the "KVoice wants to use your
/// confidential information…" password dialog. An item written without an
/// explicit ACL trusts nobody, so the only way it ever stops asking is the user
/// clicking *Always Allow* — a decision this app should not be making the user
/// discover.
///
/// So ``setAPIKey(_:)`` mints the ACL itself: delete, then add with a
/// ``SecAccess`` whose trusted-application list is exactly this app. Reads from
/// KVoice then satisfy the ACL and never prompt. Delete-then-add rather than
/// `SecItemUpdate` because `SecItemUpdate` leaves the *existing* ACL in place —
/// which is precisely what needs replacing when an old item is the reason the
/// dialog keeps appearing. Re-saving the key is therefore the repair, not just
/// a rotation.
///
/// ## The limit of this
///
/// The ACL identifies the app by its code signature, and an ad-hoc signature's
/// designated requirement is its `cdhash` — which changes on every rebuild. A
/// user who installs a new build is a *different* application as far as the ACL
/// is concerned, and gets the dialog once more. Only a stable signing identity
/// (Developer ID, or the entitlement-gated data-protection keychain that
/// identity unlocks) fixes that permanently; see the README, "Why the Keychain
/// sometimes asks for your password".
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

        // Clear the old item — and, with it, whatever ACL it carried — so the
        // add below is the sole author of who may read this key. See the type
        // comment for why this is a replace and not an update.
        try deleteAPIKey()

        let insert = Self.addQuery(
            service: service,
            account: account,
            data: data,
            access: Self.selfTrustingAccess(descriptor: descriptor)
        )
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
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

    /// ``baseQuery(service:account:)`` plus the value and the ACL to create it
    /// under. Split out from ``setAPIKey(_:)`` so the shape of the write is
    /// checkable without a keychain daemon.
    ///
    /// A nil `access` means `SecAccessCreate` was unavailable and the item is
    /// added with the system default ACL — functional, but back to prompting.
    static func addQuery(
        service: String,
        account: String,
        data: Data,
        access: SecAccess?
    ) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        // Note the absence of `kSecAttrAccessible`: it is mutually exclusive
        // with `kSecAttrAccess` (together they are `errSecParam`), and it is
        // the ACL that this item needs. Nothing is lost — an item is only
        // eligible to leave this Mac when `kSecAttrSynchronizable` is set,
        // which it never is here.
        if let access {
            query[kSecAttrAccess as String] = access
        }
        return query
    }

    // MARK: - ACL

    /// The name the system shows inside the authorization dialog, on the one
    /// occasion the user still sees it (a first save from an untrusted build).
    /// Without this the dialog quotes the raw service string.
    var descriptor: String { "KVoice AssemblyAI API key" }

    /// An access object whose trusted-application list is just this app.
    ///
    /// `SecAccessCreate` with a nil list is documented as defaulting "to (just)
    /// the application creating the item" — the same grant the user would make
    /// by clicking *Always Allow*, made up front instead.
    ///
    /// `SecAccessCreate` warns as deprecated (all of SecKeychain has been since
    /// 10.10) and is called anyway, deliberately: it is the only API that sets
    /// an ACL on a login-keychain item, and the alternative — the
    /// data-protection keychain, which needs no ACL because entitlements gate
    /// it — requires a signing identity this app does not yet have. The warning
    /// is left in place rather than annotated away, so that it keeps pointing
    /// here for whoever adds that identity.
    ///
    /// Returns nil rather than throwing if the call fails. A key that saves and
    /// prompts is worth more to the user than a save that refuses to happen.
    static func selfTrustingAccess(descriptor: String) -> SecAccess? {
        var access: SecAccess?
        let status = SecAccessCreate(descriptor as CFString, nil, &access)
        guard status == errSecSuccess else { return nil }
        return access
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
