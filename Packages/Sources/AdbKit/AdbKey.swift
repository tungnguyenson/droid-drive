import DroidCore
import Foundation
import Security

/// The RSA-2048 key DroidDrive authenticates with (spec §5.4, plan P1-05).
///
/// adbd sends a 20-byte random token and verifies `RSA_verify(NID_sha1, token, …)`,
/// i.e. a PKCS#1 v1.5 signature that treats the token as an already-computed SHA-1
/// digest. That maps to `.rsaSignatureDigestPKCS1v15SHA1`.
public final class AdbKey: @unchecked Sendable {
    // SecKey is an immutable, thread-safe CF object; it just isn't annotated Sendable.
    let privateKey: SecKey
    let publicKey: SecKey

    public init(privateKey: SecKey) throws(DeviceError) {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw .protocolError("Could not get the public key")
        }
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    public static func generate() throws(DeviceError) -> AdbKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw .protocolError("Could not create the RSA key: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return try AdbKey(privateKey: key)
    }

    /// PKCS#1 `RSAPrivateKey` DER (what `SecKeyCopyExternalRepresentation` returns).
    public convenience init(pkcs1: Data) throws(DeviceError) {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw .protocolError("Invalid RSA key: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        try self.init(privateKey: key)
    }

    /// PEM as written by adb (`~/.android/adbkey`, PKCS#8 "PRIVATE KEY") or OpenSSL
    /// ("RSA PRIVATE KEY", PKCS#1).
    public convenience init(pem: String) throws(DeviceError) {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let body = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw .protocolError("Unreadable PEM") }
        if pem.contains("BEGIN RSA PRIVATE KEY") {
            try self.init(pkcs1: der)
        } else {
            try self.init(pkcs1: try DER.pkcs8ToPKCS1(der))
        }
    }

    public func pkcs1Data() throws(DeviceError) -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw .protocolError("Could not export the key: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return data
    }

    /// Signs an AUTH TOKEN.
    public func sign(token: Data) throws(DeviceError) -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15SHA1,
                                                    token as CFData, &error) as Data? else {
            throw .protocolError("Could not sign the token: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return signature
    }

    /// The AUTH RSAPUBLICKEY payload: base64 of Android's `RSAPublicKey` struct, a space,
    /// the key's name, and a NUL (what `adb pubkey` prints, plus the NUL).
    public func androidPublicKey(name: String) throws(DeviceError) -> Data {
        var payload = Data(try androidPublicKeyBase64().utf8)
        payload.append(contentsOf: Array(" \(name)".utf8))
        payload.append(0)
        return payload
    }

    public func androidPublicKeyBase64() throws(DeviceError) -> String {
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw .protocolError("Could not export the public key")
        }
        let (modulus, exponent) = try DER.rsaPublicKey(der)
        return try AndroidRSAPublicKey.encode(modulusBigEndian: modulus, exponent: exponent).base64EncodedString()
    }
}

/// Android's binary public-key layout (`system/core/libcrypto_utils/android_pubkey.cpp`):
///
///     uint32 modulus_size_words;  // 64 for RSA-2048
///     uint32 n0inv;               // -1 / n[0] mod 2^32
///     uint8  modulus[256];        // little-endian
///     uint8  rr[256];             // R^2 mod n, R = 2^2048, little-endian
///     uint32 exponent;
enum AndroidRSAPublicKey {
    static let words = 64

    static func encode(modulusBigEndian: [UInt8], exponent: UInt32) throws(DeviceError) -> Data {
        var trimmed = modulusBigEndian
        while trimmed.first == 0 { trimmed.removeFirst() }
        guard trimmed.count == words * 4 else {
            throw .protocolError("The ADB key must be 2048-bit RSA, got \(trimmed.count * 8) bits")
        }
        let n = toWords(Array(trimmed.reversed()))
        var out = Data(capacity: 524)
        out.appendLE(UInt32(words))
        out.appendLE(n0inv(n[0]))
        n.forEach { out.appendLE($0) }
        rSquaredModN(n).forEach { out.appendLE($0) }
        out.appendLE(exponent)
        return out
    }

    /// Little-endian bytes → little-endian 32-bit words.
    static func toWords(_ littleEndian: [UInt8]) -> [UInt32] {
        stride(from: 0, to: littleEndian.count, by: 4).map { i in
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(littleEndian[i + $1]) << (8 * $1) }
        }
    }

    /// Newton iteration for the inverse of an odd number mod 2^32, negated.
    static func n0inv(_ n0: UInt32) -> UInt32 {
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- n0 &* inverse) }
        return 0 &- inverse
    }

    /// 2^4096 mod n by 4096 doublings with conditional subtraction. Slow in theory,
    /// ~1 ms in practice, and runs once per key.
    static func rSquaredModN(_ n: [UInt32]) -> [UInt32] {
        var r = [UInt32](repeating: 0, count: words + 1)
        r[0] = 1
        let modulus = n + [0]
        for _ in 0..<(words * 32 * 2) {
            var carry: UInt32 = 0
            for i in 0..<r.count {
                let next = r[i] >> 31
                r[i] = (r[i] << 1) | carry
                carry = next
            }
            if !less(r, modulus) { subtract(&r, modulus) }
        }
        return Array(r.prefix(words))
    }

    private static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i]
        }
        return false
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let diff = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            a[i] = UInt32(truncatingIfNeeded: diff)
            borrow = (diff >> 63) & 1
        }
    }
}

/// Just enough DER to unwrap PKCS#8 and read an RSA public key.
enum DER {
    struct Node {
        let tag: UInt8
        let content: [UInt8]
    }

    static func parse(_ bytes: [UInt8], at offset: inout Int) throws(DeviceError) -> Node {
        guard offset + 2 <= bytes.count else { throw .protocolError("Truncated DER") }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, offset + count <= bytes.count else { throw .protocolError("Unexpected DER length") }
            length = bytes[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
            offset += count
        }
        guard offset + length <= bytes.count else { throw .protocolError("Truncated DER") }
        defer { offset += length }
        return Node(tag: tag, content: Array(bytes[offset..<offset + length]))
    }

    static func children(_ node: Node) throws(DeviceError) -> [Node] {
        var offset = 0
        var nodes: [Node] = []
        while offset < node.content.count { nodes.append(try parse(node.content, at: &offset)) }
        return nodes
    }

    /// PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, OCTET STRING privateKey }
    static func pkcs8ToPKCS1(_ data: Data) throws(DeviceError) -> Data {
        var offset = 0
        let outer = try parse([UInt8](data), at: &offset)
        let parts = try children(outer)
        guard outer.tag == 0x30, parts.count >= 3, parts[2].tag == 0x04 else {
            throw .protocolError("Not a PKCS#8 key")
        }
        return Data(parts[2].content)
    }

    /// RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    static func rsaPublicKey(_ data: Data) throws(DeviceError) -> (modulus: [UInt8], exponent: UInt32) {
        var offset = 0
        let outer = try parse([UInt8](data), at: &offset)
        let parts = try children(outer)
        guard outer.tag == 0x30, parts.count == 2, parts[0].tag == 0x02, parts[1].tag == 0x02,
              parts[1].content.count <= 5 else {
            throw .protocolError("Invalid RSA public key")
        }
        let exponent = parts[1].content.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (parts[0].content, exponent)
    }
}
