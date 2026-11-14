import DroidCore
import Foundation
import Security
import Testing
@testable import AdbKit

@Suite("TLS certificate and identity")
struct TlsIdentityTests {
    let key: AdbKey
    init() throws { key = try AdbKey.generate() }

    @Test("certificate parses, is self-signed with the ADB key, and has adb's subject")
    func certificate() throws {
        let der = try TlsCertificate.make(for: key)
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(cert) as String? == "Adb")
        let certKey = try #require(SecCertificateCopyKey(cert))
        let a = SecKeyCopyExternalRepresentation(certKey, nil) as Data?
        let b = SecKeyCopyExternalRepresentation(key.publicKey, nil) as Data?
        #expect(a == b)
        // The signature verifies with the key it carries (self-signed).
        var offset = 0
        let outer = try DER.parse([UInt8](der), at: &offset)
        let parts = try DER.children(outer)
        #expect(parts.count == 3)
        let tbs = Data(rawTLV(der: der))
        let signature = Data(parts[2].content.dropFirst())
        #expect(SecKeyVerifySignature(key.publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                      tbs as CFData, signature as CFData, nil))
    }

    @Test("identity holds the certificate and a private key that signs for it")
    func identity() throws {
        let tls = try TlsIdentity(key: key)
        var cert: SecCertificate?
        #expect(SecIdentityCopyCertificate(tls.identity, &cert) == errSecSuccess)
        #expect(cert.map { SecCertificateCopyData($0) as Data } == tls.certificate)
        var privateKey: SecKey?
        #expect(SecIdentityCopyPrivateKey(tls.identity, &privateKey) == errSecSuccess)
        let message = Data("droiddrive".utf8)
        let signer = try #require(privateKey)
        let signature = try #require(SecKeyCreateSignature(signer, .rsaSignatureMessagePKCS1v15SHA256,
                                                           message as CFData, nil) as Data?)
        #expect(SecKeyVerifySignature(key.publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                      message as CFData, signature as CFData, nil))
    }

    @Test("DER encoder: lengths, integers, OIDs")
    func der() {
        #expect(TlsDER.integer(0) == Data([0x02, 0x01, 0x00]))
        #expect(TlsDER.integer(128) == Data([0x02, 0x02, 0x00, 0x80]))
        #expect(TlsDER.integer(unsigned: Data([0, 0, 0x7F])) == Data([0x02, 0x01, 0x7F]))
        #expect(TlsDER.oid("1.2.840.113549.1.1.11") == Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]))
        let long = TlsDER.octetString(Data(count: 300))
        #expect(Array(long.prefix(4)) == [0x04, 0x82, 0x01, 0x2C])
        #expect(TlsDER.tlv(0x04, Data(count: 0x80)).prefix(3) == Data([0x04, 0x81, 0x80]))
        let date2060 = Date(timeIntervalSince1970: 2_840_000_000)
        #expect(TlsDER.time(date2060).first == 0x18)
        #expect(TlsDER.time(Date(timeIntervalSince1970: 0)) == TlsDER.tlv(0x17, Data("700101000000Z".utf8)))
    }

    /// The raw TBSCertificate TLV (first child of the outer SEQUENCE), header included.
    private func rawTLV(der: Data) -> [UInt8] {
        let bytes = [UInt8](der)
        var offset = bytes[1] & 0x80 != 0 ? 2 + Int(bytes[1] & 0x7F) : 2
        let start = offset
        _ = try? DER.parse(bytes, at: &offset)
        return Array(bytes[start..<offset])
    }
}
