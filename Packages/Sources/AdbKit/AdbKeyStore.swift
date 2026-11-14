import DroidCore
import Foundation
import Security

/// Keeps DroidDrive's ADB key in the user's Keychain (plan P1-05, spec §5.4).
///
/// The phone remembers a public key once the user taps "Allow" on the USB debugging
/// prompt, so the private key must survive restarts and updates; losing it means the
/// prompt comes back on every phone. The key is a generic-password item holding the
/// PKCS#1 DER bytes, in the file-based login keychain: that works for the sandboxed app
/// signed without a provisioning profile, where the data-protection keychain does not.
public struct AdbKeyStore: Sendable {
    public static let defaultService = "com.droiddrive.adbkey"

    public let service: String
    public let account: String

    public init(service: String = AdbKeyStore.defaultService, account: String = "default") {
        self.service = service
        self.account = account
    }

    /// The stored key, or a new one saved for next time.
    public func loadOrCreate() throws(DeviceError) -> AdbKey {
        if let existing = try load() { return existing }
        let key = try AdbKey.generate()
        try save(key)
        return key
    }

    public func load() throws(DeviceError) -> AdbKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw .protocolError("Could not read the ADB key from the Keychain (\(status))")
        }
        return try AdbKey(pkcs1: data)
    }

    /// Stores `key`, replacing any key already stored.
    public func save(_ key: AdbKey) throws(DeviceError) {
        let data = try key.pkcs1Data()
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw .protocolError("Could not update the ADB key in the Keychain (\(update))")
        }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "DroidDrive ADB key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw .protocolError("Could not save the ADB key to the Keychain (\(added))")
        }
    }

    /// Removes the stored key; phones will ask "Allow USB debugging?" again.
    public func delete() throws(DeviceError) {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .protocolError("Could not delete the ADB key from the Keychain (\(status))")
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
