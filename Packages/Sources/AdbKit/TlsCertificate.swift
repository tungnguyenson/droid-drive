import CryptoKit
import DroidCore
import Foundation
import Security

/// The self-signed X.509 certificate Wi-Fi ADB presents in TLS, made from the ADB RSA
/// key (spec §5.4, plan P3-03/P3-05). It copies AOSP `adb/crypto/x509_generator.cpp`:
/// v3, serial 1, subject = issuer = `C=US, O=Android, CN=Adb`, valid 10 years,
/// basicConstraints `critical,CA:TRUE`, keyUsage
/// `critical,keyCertSign,cRLSign,digitalSignature`, a subject key id, signed with
/// SHA-256. The phone only checks that the certificate's public key is one it paired
/// with, so the fields matter only for matching what `adb` does.
public enum TlsCertificate {
    static let lifetime: TimeInterval = 10 * 365 * 24 * 60 * 60

    /// DER bytes of a fresh certificate for `key`.
    public static func make(for key: AdbKey, now: Date = Date()) throws(DeviceError) -> Data {
        let spki = try subjectPublicKeyInfo(key)
        let name = TlsDER.sequence([
            rdn(TlsOID.countryName, "US"),
            rdn(TlsOID.organizationName, "Android"),
            rdn(TlsOID.commonName, "Adb"),
        ])
        let signatureAlgorithm = TlsDER.algorithm(TlsOID.sha256WithRSA)
        let tbs = TlsDER.sequence([
            TlsDER.explicit(0, TlsDER.integer(2)),
            TlsDER.integer(1),
            signatureAlgorithm,
            name,
            TlsDER.sequence([TlsDER.time(now), TlsDER.time(now.addingTimeInterval(lifetime))]),
            name,
            spki.der,
            TlsDER.explicit(3, TlsDER.sequence(extensions(publicKeyBits: spki.keyBits))),
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key.privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                    tbs as CFData, &error) as Data? else {
            throw .protocolError("Could not sign the TLS certificate")
        }
        return TlsDER.sequence([tbs, signatureAlgorithm, TlsDER.bitString(signature)])
    }

    /// PKCS#8 `PrivateKeyInfo` wrapping the key's PKCS#1 DER.
    static func pkcs8(_ key: AdbKey) throws(DeviceError) -> Data {
        TlsDER.sequence([TlsDER.integer(0), TlsDER.algorithm(TlsOID.rsaEncryption),
                         TlsDER.octetString(try key.pkcs1Data())])
    }

    static func subjectPublicKeyInfo(_ key: AdbKey) throws(DeviceError) -> (der: Data, keyBits: Data) {
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key.publicKey, &error) as Data? else {
            throw .protocolError("Could not export the public key")
        }
        return (TlsDER.sequence([TlsDER.algorithm(TlsOID.rsaEncryption), TlsDER.bitString(pkcs1)]), pkcs1)
    }

    private static func rdn(_ oid: String, _ value: String) -> Data {
        TlsDER.set([TlsDER.sequence([TlsDER.oid(oid), TlsDER.printable(value)])])
    }

    private static func extensions(publicKeyBits: Data) -> [Data] {
        // keyUsage bits: digitalSignature (0) 0x80, keyCertSign (5) 0x04, cRLSign (6) 0x02.
        let keyUsage = TlsDER.bitString(Data([0x86]), unusedBits: 1)
        // Subject key id "hash" = SHA-1 of the subjectPublicKey bits (RFC 5280 §4.2.1.2).
        let keyId = Data(Insecure.SHA1.hash(data: publicKeyBits))
        return [
            TlsDER.sequence([TlsDER.oid(TlsOID.basicConstraints), TlsDER.boolean(true),
                             TlsDER.octetString(TlsDER.sequence([TlsDER.boolean(true)]))]),
            TlsDER.sequence([TlsDER.oid(TlsOID.keyUsage), TlsDER.boolean(true), TlsDER.octetString(keyUsage)]),
            TlsDER.sequence([TlsDER.oid(TlsOID.subjectKeyIdentifier),
                             TlsDER.octetString(TlsDER.octetString(keyId))]),
        ]
    }
}
