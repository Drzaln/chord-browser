import Foundation
import Security

/// The real `SecretStore`: one generic-password Keychain item per credential.
///
/// **Verified against a Release build** (App Sandbox + Hardened Runtime, ad-hoc
/// signature, `TeamIdentifier=not set`) on 2026-07-31, because `swift test` runs
/// unsandboxed and can prove none of it:
///
/// - plain items need **no** `keychain-access-groups` entitlement,
/// - they survive relaunch **and** a rebuild that changes the code signature, so
///   a vault is not lost every time the app is rebuilt.
///
/// What was measured *not* to work, and why this class looks plainer than a
/// password store should: an item carrying
/// `SecAccessControlCreateWithFlags(..., .userPresence, ...)` — the form where the
/// Keychain itself demands Touch ID — fails `SecItemAdd` with `-34018`
/// (`errSecMissingEntitlement`). That path needs the data-protection keychain and
/// an application-identifier entitlement, which requires a real signing identity.
/// So the vault's Touch ID gate is enforced by `VaultLock` in front of this class,
/// **not** by the Keychain, and is a UI lock rather than a cryptographic one. If a
/// paid signing identity ever exists, moving to access-control items is a
/// re-write of every item, not a redesign — start here.
public struct KeychainSecretStore: SecretStore {

    /// The vault service the current bundle id writes to.
    public static let defaultService = "com.rizal.chord.vault"

    /// The service the vault used under the pre-rename bundle id
    /// (`com.rizal.browser`). Only `migrateVault` reads it; nothing writes here.
    public static let legacyService = "com.rizal.browser.vault"

    /// Namespaces this app's vault items. Distinct from anything else in the
    /// login keychain, and overridable so tests never touch the real vault.
    private let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    /// One-time migration of vault secrets from the pre-rename Keychain service
    /// to the current one.
    ///
    /// The sandbox container and preferences are moved by
    /// `scripts/migrate-bundle-id.sh` (a sandboxed app cannot read its old
    /// container), but Keychain items are reachable by service string — so the
    /// actual passwords migrate here, in-app, once. Idempotent: after the first
    /// run the legacy items are deleted, so later launches no-op. Best-effort:
    /// an item that cannot be rewritten is skipped, not fatal.
    public static func migrateVault(
        from oldService: String,
        to newService: String
    ) {
        let legacy = KeychainSecretStore(service: oldService)
        let current = KeychainSecretStore(service: newService)

        for id in (try? legacy.storedCredentialIDs()) ?? [] {
            guard let secret = try? legacy.secret(for: id) else { continue }
            guard (try? current.save(secret, for: id)) != nil else { continue }
            try? legacy.delete(for: id)
        }
    }

    public func save(_ secret: String, for credentialID: UUID) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(
            query(for: credentialID) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw SecretStoreError.keychain(status: update)
        }

        var attributes = query(for: credentialID)
        attributes[kSecValueData] = data
        // Whole-device unlock is the right bar: the browser must be able to fill
        // without a prompt once the vault itself is unlocked. `ThisDeviceOnly`
        // keeps the item out of any keychain sync, matching §1's no-sync rule.
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(status: status)
        }
    }

    public func secret(for credentialID: UUID) throws -> String? {
        var lookup = query(for: credentialID)
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(status: status)
        }
        guard let data = item as? Data else { throw SecretStoreError.corruptSecret }
        guard let secret = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.corruptSecret
        }
        return secret
    }

    public func delete(for credentialID: UUID) throws {
        let status = SecItemDelete(query(for: credentialID) as CFDictionary)
        // Already gone is success: deleting a credential must not fail because
        // its secret went first.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status: status)
        }
    }

    public func storedCredentialIDs() throws -> Set<UUID> {
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(status: status)
        }
        let attributes = items as? [[CFString: Any]] ?? []
        return Set(
            attributes.compactMap { ($0[kSecAttrAccount] as? String).flatMap(UUID.init(uuidString:)) }
        )
    }

    private func query(for credentialID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: credentialID.uuidString,
        ]
    }
}
