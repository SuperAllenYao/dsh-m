import CryptoKit
import Foundation
import Security

/// Device identity: a P-256 key pair generated on first launch and persisted in
/// the Keychain. The link plugin binds the paired device credential to the
/// public key and requires an ECDSA-P256-SHA256 signature for every auth
/// challenge (protocol: /auth/challenge -> /auth/verify).
///
/// M1 uses a software P-256 key (works in the simulator); Secure Enclave
/// (`kSecAttrTokenIDSecureEnclave`) is a drop-in upgrade for device builds.
final class DeviceIdentity: @unchecked Sendable {
    static let shared = DeviceIdentity()

    private let service = "com.dshm.app.device"
    private let account = "identity-p256"
    private let lock = NSLock()
    private var cachedKey: P256.Signing.PrivateKey?

 /// base64url(SPKI DER) — the exact form the link plugin stores.
    var publicKeyBase64URL: String {
        key.publicKey.derRepresentation.base64URLEncodedString
    }

 /// ECDSA-P256-SHA256 over the UTF-8 challenge message, raw 64-byte r||s,
 /// base64url encoded (the plugin accepts raw r||s or DER).
    func signatureBase64URL(message: String) throws -> String {
        let signature = try key.signature(for: Data(message.utf8))
        return signature.rawRepresentation.base64URLEncodedString
    }

    private var key: P256.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        if let data = load(), let loaded = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            cachedKey = loaded
            return loaded
        }
        let generated = P256.Signing.PrivateKey()
        save(generated.rawRepresentation)
        cachedKey = generated
        return generated
    }

    private func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return data
        }
        #if targetEnvironment(simulator)
        return try? Data(contentsOf: Self.fallbackURL)
        #else
        return nil
        #endif
    }

    private func save(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        #if targetEnvironment(simulator)
 // Same unsigned-simulator limitation as CredentialStore.
        try? data.write(to: Self.fallbackURL, options: [.atomic])
        NSLog("[DSHm] device key keychain save status=%d (simulator fallback file used)", status)
        #endif
    }

    private static var fallbackURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("device-identity-p256.bin")
    }
}
