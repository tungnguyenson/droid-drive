import AdbKit
import DroidCore
import Foundation

/// The pairing exchange on an established TLS channel, both roles (AOSP
/// `pairing_connection.cpp`, plan P3-03):
///
/// 1. Both export 64 bytes of TLS keying material, label `"adb-label\0"` (10 bytes:
///    adb passes `sizeof` of the C string, so the NUL counts), and append it to the
///    code. A man in the middle has two TLS sessions, so the passwords differ.
/// 2. Both send `SPAKE2_MSG` with their 32-byte message, then read the peer's.
/// 3. Both send `PEER_INFO`, AES-128-GCM encrypted, then read and decrypt the peer's.
///    A wrong code shows up here: the phone cannot decrypt ours and hangs up, or we
///    cannot decrypt theirs.
struct PairingSession {
    static let exporterLabel = Data("adb-label\0".utf8)
    static let exporterLength = 64

    enum Role { case client, server }

    let channel: any PairingChannel
    let role: Role

    /// Runs the exchange and returns the peer's info.
    func run(code: Data, ourInfo: PeerInfo) async throws -> PeerInfo {
        let exported = try channel.exportKeyingMaterial(label: Self.exporterLabel, length: Self.exporterLength)
        let auth = try PairingAuth(role: role == .client ? .client : .server, password: code + exported)

        try await write(.spake2Message, auth.message)
        let theirMessage = try await read(.spake2Message)
        try auth.initCipher(theirMessage: theirMessage)

        try await write(.peerInfo, try auth.encrypt(ourInfo.encoded()))
        let sealed: Data
        do {
            sealed = try await read(.peerInfo)
        } catch DeviceError.disconnected {
            // The phone closes the socket when our PeerInfo does not decrypt.
            throw WifiPairingError.wrongCode
        }
        return try PeerInfo.decode(try auth.decrypt(sealed))
    }

    private func write(_ type: PairingPacketHeader.PacketType, _ payload: Data) async throws {
        let header = PairingPacketHeader(type: type, payloadSize: UInt32(payload.count))
        try await channel.write(header.encoded() + payload)
    }

    private func read(_ expected: PairingPacketHeader.PacketType) async throws -> Data {
        let header = try PairingPacketHeader.decode(try await readExactly(PairingPacketHeader.size))
        guard header.type == expected else {
            throw DeviceError.protocolError("Expected pairing packet \(expected), got \(header.type)")
        }
        return try await readExactly(Int(header.payloadSize))
    }

    private func readExactly(_ count: Int) async throws -> Data {
        var out = Data()
        while out.count < count {
            guard let chunk = try await channel.readChunk(max: count - out.count) else {
                throw DeviceError.disconnected
            }
            out.append(chunk)
        }
        return out
    }
}

/// The byte channel a pairing runs on: `TlsChannel` in production, an in-memory pair
/// in tests.
protocol PairingChannel: Sendable {
    func write(_ data: Data) async throws
    /// Up to `max` bytes, nil at end of stream. Extra bytes are kept for the next call.
    func readChunk(max: Int) async throws -> Data?
    func exportKeyingMaterial(label: Data, length: Int) throws -> Data
}

/// Adapts `TlsChannel` (whose reads return whatever arrived) to exact-size reads.
final class TlsPairingChannel: PairingChannel, @unchecked Sendable {
    private let channel: TlsChannel
    private let lock = NSLock()
    private var leftover = Data()

    init(_ channel: TlsChannel) { self.channel = channel }

    func write(_ data: Data) async throws { try await channel.write(data) }

    func readChunk(max: Int) async throws -> Data? {
        if let buffered = takeLeftover(max: max) { return buffered }
        while true {
            guard let chunk = try await channel.read() else { return nil }
            if chunk.isEmpty { continue }
            if chunk.count <= max { return chunk }
            lock.withLock { leftover = Data(chunk.dropFirst(max)) }
            return Data(chunk.prefix(max))
        }
    }

    private func takeLeftover(max: Int) -> Data? {
        lock.withLock {
            guard !leftover.isEmpty else { return nil }
            let out = Data(leftover.prefix(max))
            leftover = Data(leftover.dropFirst(max))
            return out
        }
    }

    func exportKeyingMaterial(label: Data, length: Int) throws -> Data {
        try channel.exportKeyingMaterial(label: label, length: length)
    }
}
