import CryptoKit
import Foundation
import Security

/// Encrypts clipboard history at rest with a per-user key kept in Keychain.
/// Plaintext is accepted only for one-way migration of files written by older
/// versions; every new write must pass through `seal`.
enum ClipboardStorageCrypto {
    nonisolated private static let magic = Data("EMC1".utf8)
    nonisolated private static let service = "com.easymactool.clipboard"
    nonisolated private static let account = "history-key-v1"

    private enum CryptoError: Error {
        case keychain(OSStatus)
        case invalidCiphertext
    }

    nonisolated private static func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw CryptoError.keychain(status) }

        var keyBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes) == errSecSuccess else {
            throw CryptoError.keychain(errSecIO)
        }
        let data = Data(keyBytes)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess || addStatus == errSecDuplicateItem {
            // A concurrent process may have won the race; read the canonical key.
            return try key()
        }
        throw CryptoError.keychain(addStatus)
    }

    nonisolated static func seal(_ plaintext: Data) -> Data? {
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key())
            guard let combined = sealed.combined else { return nil }
            return magic + combined
        } catch {
            return nil
        }
    }

    /// Returns decrypted data for encrypted files, or the original bytes for
    /// legacy plaintext files. A malformed encrypted file is rejected.
    nonisolated static func openOrLegacy(_ data: Data) -> Data? {
        guard data.starts(with: magic) else { return data }
        let payload = data.dropFirst(magic.count)
        guard let box = try? AES.GCM.SealedBox(combined: payload),
              let cryptoKey = try? key(),
              let plaintext = try? AES.GCM.open(box, using: cryptoKey) else {
            return nil
        }
        return plaintext
    }

    nonisolated static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    nonisolated static func openFileOrLegacy(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return openOrLegacy(data)
    }
}
