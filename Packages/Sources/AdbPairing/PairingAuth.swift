import CryptoKit
import DroidCore
import Foundation

/// SPAKE2 plus the AES-128-GCM channel it keys, as in AOSP `adb/pairing_auth`
/// (`pairing_auth.cpp`, `aes_128_gcm.cpp`):
///
/// - SPAKE2 names include the C string's NUL: `"adb pair client\0"`, `"adb pair server\0"`;
///   the client is Alice.
/// - The password is the 6-digit code (or the QR password) followed by 64 bytes of TLS
///   keying material, which ties the exchange to this TLS session.
/// - Key: HKDF-SHA256 over SPAKE2's 64-byte output, no salt, info
///   `"adb pairing_auth aes-128-gcm key"` (no NUL), 16 bytes.
/// - Nonce: 12 bytes, the first 8 a little-endian counter per direction starting at 0.
///   Output is ciphertext followed by the 16-byte tag, no nonce on the wire.
final class PairingAuth {
    enum Role { case client, server }

    static let clientName = Data("adb pair client\0".utf8)
    static let serverName = Data("adb pair server\0".utf8)
    static let hkdfInfo = Data("adb pairing_auth aes-128-gcm key".utf8)
    static let tagSize = 16

    let message: Data
    private let spake: Spake2
    private var key: SymmetricKey?
    private var encryptCounter: UInt64 = 0
    private var decryptCounter: UInt64 = 0

    init(role: Role, password: Data) throws(DeviceError) {
        guard !password.isEmpty else { throw .protocolError("The pairing code is empty") }
        spake = try Spake2(role: role == .client ? .alice : .bob,
                           myName: role == .client ? Self.clientName : Self.serverName,
                           theirName: role == .client ? Self.serverName : Self.clientName)
        message = try spake.generateMessage(password: password)
    }

    /// Derives the cipher key from the peer's SPAKE2 message. Call once.
    func initCipher(theirMessage: Data) throws(DeviceError) {
        guard key == nil else { throw .protocolError("Pairing cipher already set up") }
        guard theirMessage.count <= Spake2.messageSize else {
            throw .protocolError("Pairing message too large (\(theirMessage.count) bytes)")
        }
        let material = try spake.processMessage(theirMessage)
        key = Self.deriveKey(material)
    }

    static func deriveKey(_ material: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material),
                               info: hkdfInfo, outputByteCount: 16)
    }

    func encrypt(_ plaintext: Data) throws(DeviceError) -> Data {
        guard let key else { throw .protocolError("Pairing cipher not set up") }
        do {
            let box = try AES.GCM.seal(plaintext, using: key, nonce: try Self.nonce(encryptCounter))
            encryptCounter += 1
            return box.ciphertext + box.tag
        } catch {
            throw .protocolError("Could not encrypt the pairing data")
        }
    }

    /// Throws when the data was not encrypted with our key: in practice, a wrong code.
    func decrypt(_ sealed: Data) throws -> Data {
        guard let key else { throw DeviceError.protocolError("Pairing cipher not set up") }
        guard sealed.count >= Self.tagSize else { throw WifiPairingError.wrongCode }
        do {
            let box = try AES.GCM.SealedBox(nonce: try Self.nonce(decryptCounter),
                                            ciphertext: sealed.dropLast(Self.tagSize),
                                            tag: sealed.suffix(Self.tagSize))
            let plain = try AES.GCM.open(box, using: key)
            decryptCounter += 1
            return plain
        } catch {
            throw WifiPairingError.wrongCode
        }
    }

    static func nonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data(count: 12)
        withUnsafeBytes(of: counter.littleEndian) { bytes.replaceSubrange(0..<8, with: $0) }
        return try AES.GCM.Nonce(data: bytes)
    }
}
