import CommonCrypto
import Foundation
import Security

/// Opens a value Grok Bot sealed with Electron's `safeStorage` — Chromium's
/// macOS scheme: a random password in the login keychain, stretched with
/// PBKDF2 into an AES-128-CBC key, ciphertext prefixed with "v10".
///
/// Reading the password makes macOS ask once whether SideNotch may use
/// "Grok Bot Safe Storage". The derived key lives in memory only.
enum SafeStorage {
    private static let service = "Grok Bot Safe Storage"
    private static let account = "Grok Bot Key"

    private static var cachedKey: Data?
    private static let lock = NSLock()

    static func decrypt(_ sealed: Data) -> String? {
        let prefix = Data("v10".utf8)
        guard sealed.starts(with: prefix), let key = key() else { return nil }
        let body = sealed.dropFirst(prefix.count)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

        var out = Data(count: body.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var written = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            body.withUnsafeBytes { inPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                inPtr.baseAddress, body.count,
                                outPtr.baseAddress, outCapacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: out.prefix(written), encoding: .utf8)
    }

    private static func key() -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let cachedKey { return cachedKey }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let password = item as? Data else { return nil }

        let salt = Data("saltysalt".utf8)
        var derived = Data(count: kCCKeySizeAES128)
        let derivedCount = derived.count
        let status = derived.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { pwPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pwPtr.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), derivedCount)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        cachedKey = derived
        return derived
    }
}
