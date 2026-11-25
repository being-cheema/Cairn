import CryptoKit
import Foundation
import Security

/// The passkeys Cairn keeps itself (SPEC-passkeys.md): one keychain item each.
/// The private key is the item's secret; everything a list needs sits in the
/// item's attributes, so listing and looking one up never read a secret (and
/// never prompt). Only `key(for:)` does, at the moment of signing.
enum PasskeyStore {
    /// Apart from Vault's internet passwords by class, and from anything else
    /// of ours by service.
    private static let service = "\(Brand.bundleID).passkey"

    /// What every item of ours is tagged with; a test run tags its own, as
    /// Vault does, so a passkey made while trying something never sits among
    /// the real ones.
    private static let label = Store.world.map { "\(Brand.keychainLabel) (\($0))" } ?? Brand.keychainLabel

    /// The fields beyond the account, as JSON in the item's generic attribute.
    private struct Fields: Codable {
        var userHandle: Data
        var userName: String
        var displayName: String
        var created: Date
        var lastUsed: Date?
        /// Optional: items kept before it existed read as made here.
        var backupEligible: Bool?
    }

    private static func account(_ record: PasskeyRecord) -> String { record.id }

    // MARK: - reading

    /// Every passkey, newest first. Attributes only: no key is read.
    static func all() -> [PasskeyRecord] {
        rows(where: [:]).compactMap(record(from:)).sorted { $0.created > $1.created }
    }

    /// The ones for a site, newest first. `allowed` empty means every one the
    /// site has; otherwise only those whose credential id is listed.
    static func records(rp: String, allowed: [Data]) -> [PasskeyRecord] {
        let wanted = Set(allowed)
        return all().filter { $0.rp == rp && (wanted.isEmpty || wanted.contains($0.credentialID)) }
    }

    /// The one place a secret is read.
    static func key(for record: PasskeyRecord) -> P256.Signing.PrivateKey? {
        var query = identity(record)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let raw = out as? Data else { return nil }
        return try? P256.Signing.PrivateKey(rawRepresentation: raw)
    }

    // MARK: - writing

    /// Keeps it. A site gets one passkey per person (WebAuthn), so one of the
    /// same rp and user handle that was kept before is replaced, and only once
    /// the new one is safely in.
    @discardableResult
    static func save(_ record: PasskeyRecord, key: P256.Signing.PrivateKey) -> Bool {
        guard !record.rp.isEmpty, let generic = encode(record) else { return false }
        var fresh = identity(record)
        fresh[kSecValueData as String] = key.rawRepresentation
        fresh[kSecAttrGeneric as String] = generic
        // As Vault does: our own security domain keeps the keychain's
        // duplicate check from ever matching another app's item.
        fresh[kSecAttrSecurityDomain as String] = Brand.bundleID
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        var status = SecItemAdd(fresh as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // The same credential again: take the new key and fields over it.
            status = SecItemUpdate(identity(record) as CFDictionary, [
                kSecValueData as String: key.rawRepresentation,
                kSecAttrGeneric as String: generic,
            ] as CFDictionary)
        }
        guard status == errSecSuccess else { return false }
        for old in records(rp: record.rp, allowed: []) where old.userHandle == record.userHandle && old.id != record.id {
            remove(old)
        }
        return true
    }

    /// It was just used to sign in.
    static func touch(_ record: PasskeyRecord) {
        var used = record
        used.lastUsed = Date()
        guard let generic = encode(used) else { return }
        SecItemUpdate(identity(record) as CFDictionary, [kSecAttrGeneric as String: generic] as CFDictionary)
    }

    /// Whether the keychain let it go.
    @discardableResult
    static func remove(_ record: PasskeyRecord) -> Bool {
        SecItemDelete(identity(record) as CFDictionary) == errSecSuccess
    }

    // MARK: - keychain plumbing

    /// Ours only, and this one only.
    private static func identity(_ record: PasskeyRecord) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(record),
            kSecAttrLabel as String: label,
        ]
    }

    private static func rows(where extra: [String: Any]) -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrLabel as String: label,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        extra.forEach { query[$0] = $1 }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
            // Nothing kept reads as "not found"; anything else is worth a line.
            if status != errSecItemNotFound { NSLog("PasskeyStore: keychain list failed (%d)", status) }
            return []
        }
        return rows
    }

    private static func encode(_ record: PasskeyRecord) -> Data? {
        try? JSONEncoder().encode(Fields(userHandle: record.userHandle, userName: record.userName,
                                         displayName: record.displayName, created: record.created,
                                         lastUsed: record.lastUsed, backupEligible: record.backupEligible ? true : nil))
    }

    private static func record(from row: [String: Any]) -> PasskeyRecord? {
        guard let account = row[kSecAttrAccount as String] as? String,
              let generic = row[kSecAttrGeneric as String] as? Data,
              let fields = try? JSONDecoder().decode(Fields.self, from: generic)
        else { return nil }
        let parts = account.components(separatedBy: "\u{1}")
        guard parts.count == 2, let id = Data(base64Encoded: parts[1]) else { return nil }
        return PasskeyRecord(rp: parts[0], credentialID: id, userHandle: fields.userHandle, userName: fields.userName,
                             displayName: fields.displayName, created: fields.created, lastUsed: fields.lastUsed,
                             backupEligible: fields.backupEligible ?? false)
    }
}
