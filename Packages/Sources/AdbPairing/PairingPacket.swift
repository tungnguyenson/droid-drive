import DroidCore
import Foundation

/// The 6-byte header in front of every pairing message (AOSP
/// `pairing_connection.cpp`, `struct PairingPacketHeader`, packed):
///
///     uint8  version   // 1
///     uint8  type      // PairingPacket.Type from pairing.proto
///     uint32 payload   // big-endian (htonl), 1...16384
struct PairingPacketHeader: Equatable {
    enum PacketType: UInt8 {
        case spake2Message = 0
        case peerInfo = 1
    }

    static let size = 6
    static let version: UInt8 = 1
    /// `kMaxPeerInfoSize * 2`: an encrypted PeerInfo plus room to spare.
    static let maxPayload = UInt32(PeerInfo.size * 2)

    let type: PacketType
    let payloadSize: UInt32

    func encoded() -> Data {
        var data = Data([Self.version, type.rawValue])
        withUnsafeBytes(of: payloadSize.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func decode(_ bytes: Data) throws(DeviceError) -> PairingPacketHeader {
        let b = [UInt8](bytes)
        guard b.count == size else { throw .protocolError("Pairing header is truncated") }
        guard b[0] == version else { throw .protocolError("Unsupported pairing version \(b[0])") }
        guard let type = PacketType(rawValue: b[1]) else {
            throw .protocolError("Unknown pairing packet type \(b[1])")
        }
        let payload = b[2...5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard payload > 0, payload <= maxPayload else {
            throw .protocolError("Pairing payload size out of range: \(payload)")
        }
        return PairingPacketHeader(type: type, payloadSize: payload)
    }
}

/// What each side tells the other once SPAKE2 succeeded (AOSP
/// `pairing_connection.h`, `struct PeerInfo`): exactly 8192 bytes, a type byte then
/// NUL-padded data.
///
/// - We send `ADB_RSA_PUB_KEY`: our key as `adb pubkey` prints it
///   (`<base64 Android RSAPublicKey> <name>`). The phone adds it to its trusted keys.
/// - The phone sends `ADB_DEVICE_GUID`: the name it will advertise as
///   `_adb-tls-connect._tcp` (e.g. `adb-R5CT20ABCDE-xYz12A`).
public struct PeerInfo: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case rsaPublicKey = 0
        case deviceGuid = 1
    }

    static let size = 8192

    public let type: UInt8
    /// Data up to the first NUL.
    public let data: Data

    public init(type: UInt8, data: Data) {
        self.type = type
        self.data = data
    }

    public var kind: Kind? { Kind(rawValue: type) }
    public var text: String { String(decoding: data, as: UTF8.self) }

    /// Our public key, as adb sends it (no NUL inside; padding provides the terminator).
    static func publicKey(_ adbPublicKey: String) throws(DeviceError) -> PeerInfo {
        let bytes = Data(adbPublicKey.utf8)
        guard bytes.count <= size - 2, !bytes.contains(0) else {
            throw .protocolError("The public key does not fit in the pairing message")
        }
        return PeerInfo(type: Kind.rsaPublicKey.rawValue, data: bytes)
    }

    func encoded() -> Data {
        var out = Data([type])
        out.append(data.prefix(Self.size - 1))
        out.append(Data(count: Self.size - out.count))
        return out
    }

    static func decode(_ bytes: Data) throws(DeviceError) -> PeerInfo {
        guard bytes.count == size else {
            throw .protocolError("Peer info has \(bytes.count) bytes, expected \(size)")
        }
        let body = bytes.dropFirst()
        let end = body.firstIndex(of: 0) ?? body.endIndex
        return PeerInfo(type: bytes[bytes.startIndex], data: Data(body[body.startIndex..<end]))
    }
}
