import CommonCrypto
import CryptoKit
import DroidCore
import Foundation
import os
import Security

/// The ADB key plus its self-signed certificate as a `SecIdentity`, which is what
/// Network.framework's TLS wants for a client (or server) certificate
/// (`sec_protocol_options_set_local_identity`, spec §5.4).
///
/// macOS has no public call that pairs a `SecKey` with a certificate in memory, so the
/// identity goes through a PKCS#12 bundle built here and `SecPKCS12Import`:
/// - macOS 15+: `kSecImportToMemoryOnly`, nothing touches the Keychain.
/// - macOS 13–14: the import lands in the default (login) keychain, labelled
///   "DroidDrive ADB TLS"; a second import of the same key is a duplicate and the
///   identity is looked up from the certificate instead.
///
/// Apple's importer ignores an unencrypted key bag and refuses a bundle without a MAC
/// (tried 14/11/2026), hence PBES2/AES-256-CBC for the key and an HMAC-SHA256 MAC, as
/// OpenSSL 3 writes by default. The bundle password is random and never leaves memory.
public final class TlsIdentity: @unchecked Sendable {
    // SecIdentity is an immutable CF object; it just isn't annotated Sendable.
    public let identity: SecIdentity
    /// DER of the certificate inside `identity`.
    public let certificate: Data

    private static let logger = Logger(subsystem: "com.droiddrive", category: "tls")
    static let label = "DroidDrive ADB TLS"

    public init(key: AdbKey) throws(DeviceError) {
        let certificate = try TlsCertificate.make(for: key)
        let password = Self.randomPassword()
        let bundle = try PKCS12.make(key: try TlsCertificate.pkcs8(key), certificate: certificate,
                                     password: password, friendlyName: Self.label)
        self.identity = try Self.importBundle(bundle, password: password, certificate: certificate)
        self.certificate = certificate
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private static func importBundle(_ bundle: Data, password: String, certificate: Data) throws(DeviceError) -> SecIdentity {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        let status = SecPKCS12Import(bundle as CFData, options as CFDictionary, &items)
        if status == errSecSuccess,
           let first = (items as? [[String: Any]])?.first,
           let value = first[kSecImportItemIdentity as String] {
            return value as! SecIdentity // swiftlint:disable:this force_cast (CF type, cast cannot fail)
        }
        // macOS 13–14 only: the identity is already in the keychain from an earlier run.
        guard status == errSecDuplicateItem || status == errSecSuccess else {
            logger.error("PKCS#12 import failed: \(status)")
            throw .protocolError("Could not create the TLS identity (\(status))")
        }
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData) else {
            throw .protocolError("Invalid TLS certificate")
        }
        var identity: SecIdentity?
        let found = SecIdentityCreateWithCertificate(nil, cert, &identity)
        guard found == errSecSuccess, let identity else {
            throw .protocolError("Could not find the TLS identity in the keychain (\(found))")
        }
        return identity
    }
}

/// A minimal PKCS#12 (RFC 7292) writer: one PBES2-encrypted key bag, one plain
/// certificate bag, both tagged with the same localKeyId, and an HMAC-SHA256 MAC.
enum PKCS12 {
    static let iterations = 2048

    static func make(key pkcs8: Data, certificate: Data, password: String, friendlyName: String) throws(DeviceError) -> Data {
        let keyId = Data(Insecure.SHA1.hash(data: certificate))
        let attributes = TlsDER.set([
            TlsDER.sequence([TlsDER.oid(TlsOID.friendlyName), TlsDER.set([TlsDER.bmpString(friendlyName)])]),
            TlsDER.sequence([TlsDER.oid(TlsOID.localKeyId), TlsDER.set([TlsDER.octetString(keyId)])]),
        ])
        let keyBag = TlsDER.sequence([
            TlsDER.oid(TlsOID.pkcs8ShroudedKeyBag),
            TlsDER.explicit(0, try encryptedPrivateKeyInfo(pkcs8, password: password)),
            attributes,
        ])
        let certBag = TlsDER.sequence([
            TlsDER.oid(TlsOID.certBag),
            TlsDER.explicit(0, TlsDER.sequence([TlsDER.oid(TlsOID.x509Certificate),
                                                TlsDER.explicit(0, TlsDER.octetString(certificate))])),
            attributes,
        ])
        let authSafe = TlsDER.sequence([
            dataContentInfo(TlsDER.sequence([certBag])),
            dataContentInfo(TlsDER.sequence([keyBag])),
        ])
        let macSalt = random(16)
        let macKey = kdf(password: password, salt: macSalt, id: 3, iterations: iterations, length: 32)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: authSafe, using: SymmetricKey(data: macKey)))
        return TlsDER.sequence([
            TlsDER.integer(3),
            dataContentInfo(authSafe),
            TlsDER.sequence([
                TlsDER.sequence([TlsDER.algorithm(TlsOID.sha256), TlsDER.octetString(mac)]),
                TlsDER.octetString(macSalt),
                TlsDER.integer(iterations),
            ]),
        ])
    }

    static func dataContentInfo(_ content: Data) -> Data {
        TlsDER.sequence([TlsDER.oid(TlsOID.data), TlsDER.explicit(0, TlsDER.octetString(content))])
    }

    /// `EncryptedPrivateKeyInfo` with PBES2: PBKDF2-HMAC-SHA256 then AES-256-CBC.
    static func encryptedPrivateKeyInfo(_ pkcs8: Data, password: String) throws(DeviceError) -> Data {
        let salt = random(16)
        let iv = random(16)
        let key = try pbkdf2(password: password, salt: salt, iterations: iterations, length: 32)
        let ciphertext = try aesCBC(pkcs8, key: key, iv: iv)
        let params = TlsDER.sequence([
            TlsDER.sequence([
                TlsDER.oid(TlsOID.pbkdf2),
                TlsDER.sequence([TlsDER.octetString(salt), TlsDER.integer(iterations),
                                 TlsDER.algorithm(TlsOID.hmacWithSHA256)]),
            ]),
            TlsDER.sequence([TlsDER.oid(TlsOID.aes256CBC), TlsDER.octetString(iv)]),
        ])
        return TlsDER.sequence([TlsDER.sequence([TlsDER.oid(TlsOID.pbes2), params]), TlsDER.octetString(ciphertext)])
    }

    /// RFC 7292 Appendix B.2 key derivation with SHA-256 (u = 32, v = 64). DroidDrive
    /// only needs one block (the 32-byte MAC key), so the I-update step is not needed.
    static func kdf(password: String, salt: Data, id: UInt8, iterations: Int, length: Int) -> Data {
        precondition(length <= 32)
        let v = 64
        var passwordBytes = Data(password.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        passwordBytes.append(contentsOf: [0, 0])
        func stretch(_ data: Data) -> Data {
            guard !data.isEmpty else { return Data() }
            let count = v * ((data.count + v - 1) / v)
            return Data((0..<count).map { data[data.startIndex + $0 % data.count] })
        }
        var a = Data(repeating: id, count: v) + stretch(salt) + stretch(passwordBytes)
        for _ in 0..<iterations { a = Data(SHA256.hash(data: a)) }
        return a.prefix(length)
    }

    static func pbkdf2(password: String, salt: Data, iterations: Int, length: Int) throws(DeviceError) -> Data {
        var out = [UInt8](repeating: 0, count: length)
        let passwordBytes = Array(password.utf8)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, passwordBytes.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                 &out, length)
        }
        guard status == kCCSuccess else { throw .protocolError("PBKDF2 failed (\(status))") }
        return Data(out)
    }

    static func aesCBC(_ plaintext: Data, key: Data, iv: Data) throws(DeviceError) -> Data {
        var out = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var written = 0
        let status = plaintext.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            input.baseAddress, plaintext.count, &out, out.count, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw .protocolError("AES failed (\(status))") }
        return Data(out.prefix(written))
    }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
