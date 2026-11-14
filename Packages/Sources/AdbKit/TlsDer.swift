import Foundation

/// Just enough DER *encoding* to build the self-signed certificate and the PKCS#12
/// bundle that Wi-Fi ADB needs (plan P3-03/P3-05). Parsing lives in `DER` (AdbKey.swift).
enum TlsDER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var bytes: [UInt8] = []
            var value = n
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(content)
        return out
    }

    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func octetString(_ data: Data) -> Data { tlv(0x04, data) }
    static func bitString(_ data: Data, unusedBits: UInt8 = 0) -> Data { tlv(0x03, Data([unusedBits]) + data) }
    static func boolean(_ value: Bool) -> Data { tlv(0x01, Data([value ? 0xFF : 0x00])) }
    static let null = Data([0x05, 0x00])
    static func printable(_ text: String) -> Data { tlv(0x13, Data(text.utf8)) }
    static func bmpString(_ text: String) -> Data {
        tlv(0x1E, Data(text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }))
    }
    /// `[n] EXPLICIT`.
    static func explicit(_ number: UInt8, _ content: Data) -> Data { tlv(0xA0 | number, content) }

    static func integer(_ value: Int) -> Data {
        precondition(value >= 0)
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return integer(unsigned: Data(bytes))
    }

    /// A non-negative big-endian integer: strips leading zeros, adds one if the top bit is set.
    static func integer(unsigned bigEndian: Data) -> Data {
        var bytes = [UInt8](bigEndian.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").map { UInt64($0)! }
        var body = Data([UInt8(parts[0] * 40 + parts[1])])
        for var part in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(part & 0x7F)]
            part >>= 7
            while part > 0 {
                chunk.insert(UInt8(part & 0x7F) | 0x80, at: 0)
                part >>= 7
            }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    /// `UTCTime` until 2049, `GeneralizedTime` after (RFC 5280 §4.1.2.5).
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: formatter.timeZone, from: date).year ?? 2000
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Data(formatter.string(from: date).utf8))
    }

    static func algorithm(_ oid: String, parameters: Data? = TlsDER.null) -> Data {
        sequence([TlsDER.oid(oid)] + (parameters.map { [$0] } ?? []))
    }
}

/// Object identifiers used by the certificate and PKCS#12 code.
enum TlsOID {
    static let rsaEncryption = "1.2.840.113549.1.1.1"
    static let sha256WithRSA = "1.2.840.113549.1.1.11"
    static let countryName = "2.5.4.6"
    static let organizationName = "2.5.4.10"
    static let commonName = "2.5.4.3"
    static let basicConstraints = "2.5.29.19"
    static let keyUsage = "2.5.29.15"
    static let subjectKeyIdentifier = "2.5.29.14"
    static let data = "1.2.840.113549.1.7.1"
    static let pkcs8ShroudedKeyBag = "1.2.840.113549.1.12.10.1.2"
    static let certBag = "1.2.840.113549.1.12.10.1.3"
    static let x509Certificate = "1.2.840.113549.1.9.22.1"
    static let localKeyId = "1.2.840.113549.1.9.21"
    static let friendlyName = "1.2.840.113549.1.9.20"
    static let pbes2 = "1.2.840.113549.1.5.13"
    static let pbkdf2 = "1.2.840.113549.1.5.12"
    static let hmacWithSHA256 = "1.2.840.113549.2.9"
    static let aes256CBC = "2.16.840.1.101.3.4.1.42"
    static let sha256 = "2.16.840.1.101.3.4.2.1"
}
