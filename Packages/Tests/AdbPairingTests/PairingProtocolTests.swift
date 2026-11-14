import AdbKit
import DroidCore
import Foundation
import Testing
@testable import AdbPairing

@Suite("Pairing packets")
struct PairingPacketTests {
    @Test("header is version, type, big-endian size")
    func header() throws {
        let header = PairingPacketHeader(type: .peerInfo, payloadSize: 8208)
        #expect(header.encoded() == Data([1, 1, 0x00, 0x00, 0x20, 0x10]))
        #expect(try PairingPacketHeader.decode(header.encoded()) == header)
        #expect(try PairingPacketHeader.decode(Data([1, 0, 0, 0, 0, 32])).type == .spake2Message)
    }

    @Test("bad headers are refused", arguments: [
        Data([2, 0, 0, 0, 0, 32]),          // version
        Data([1, 9, 0, 0, 0, 32]),          // type
        Data([1, 0, 0, 0, 0, 0]),           // empty
        Data([1, 0, 0, 0, 0x40, 0x01]),     // > 16384
        Data([1, 0, 0, 0, 32]),             // truncated
    ])
    func badHeader(_ bytes: Data) {
        #expect(throws: DeviceError.self) { try PairingPacketHeader.decode(bytes) }
    }

    @Test("PeerInfo is 8192 bytes: type then NUL-padded data")
    func peerInfo() throws {
        let info = try PeerInfo.publicKey("QUFBQQ== me@mac")
        let bytes = info.encoded()
        #expect(bytes.count == 8192)
        #expect(bytes[0] == 0)
        #expect(bytes[1...15] == Data("QUFBQQ== me@mac".utf8)[...])
        #expect(bytes[16] == 0)
        let decoded = try PeerInfo.decode(bytes)
        #expect(decoded == info)
        #expect(decoded.kind == .rsaPublicKey)
        #expect(try PeerInfo.decode(PeerInfo(type: 1, data: Data("adb-X-1".utf8)).encoded()).text == "adb-X-1")
        #expect(throws: DeviceError.self) { try PeerInfo.decode(Data(count: 100)) }
        #expect(throws: DeviceError.self) { try PeerInfo.publicKey(String(repeating: "a", count: 8191)) }
    }

    @Test("AES-GCM framing: counter nonces, tag appended, per-direction counters")
    func cipherFraming() throws {
        let client = try PairingAuth(role: .client, password: Data("000000".utf8))
        let server = try PairingAuth(role: .server, password: Data("000000".utf8))
        try client.initCipher(theirMessage: server.message)
        try server.initCipher(theirMessage: client.message)
        let first = try client.encrypt(Data("one".utf8))
        let second = try client.encrypt(Data("one".utf8))
        #expect(first.count == 3 + 16)
        #expect(first != second) // different nonce
        #expect(try server.decrypt(first) == Data("one".utf8))
        #expect(try server.decrypt(second) == Data("one".utf8))
        // Out of order: the counter no longer matches.
        let third = try client.encrypt(Data("x".utf8))
        _ = try client.encrypt(Data("y".utf8))
        #expect(try server.decrypt(third) == Data("x".utf8))
        #expect(throws: WifiPairingError.wrongCode) { try server.decrypt(Data(count: 5)) }
        #expect(try PairingAuth.nonce(1).withUnsafeBytes { Data($0) } == Data([1] + [UInt8](repeating: 0, count: 11)))
    }

    @Test("HKDF key matches an independent computation")
    func hkdf() {
        // Python: hkdf_sha256(ikm=bytes(range(64)), salt=b"", info=b"adb pairing_auth aes-128-gcm key", 16)
        let key = PairingAuth.deriveKey(Data((0..<64).map { UInt8($0) }))
        #expect(key.withUnsafeBytes { Data($0) }.hex == "5e234c26fa41fb42e5d493b262c0def1")
    }

    @Test("addresses parse", arguments: [
        ("192.168.1.23:37123", "192.168.1.23", UInt16(37123)),
        (" 10.0.0.2:5555 ", "10.0.0.2", UInt16(5555)),
        ("[fe80::1%en0]:41234", "fe80::1%en0", UInt16(41234)),
        ("android.local:1", "android.local", UInt16(1)),
    ])
    func address(_ text: String, _ host: String, _ port: UInt16) throws {
        let parsed = try PairingClient.parseAddress(text)
        #expect(parsed.host == host && parsed.port == port)
    }

    @Test("bad addresses are refused", arguments: ["192.168.1.23", ":5555", "host:0", "host:99999", "a b:1", "fe80::1:5555"])
    func badAddress(_ text: String) {
        #expect(throws: WifiPairingError.self) { try PairingClient.parseAddress(text) }
    }
}

@Suite("Pairing over TLS on this Mac", .serialized)
struct PairingLoopbackTests {
    let connector: WifiConnector
    let serverIdentity: TlsIdentity

    init() throws {
        connector = try WifiConnector(key: try AdbKey.generate(), keyName: "test@droiddrive")
        serverIdentity = try TlsIdentity(key: try AdbKey.generate())
    }

    @Test("client and server agree; each gets the other's PeerInfo")
    func pairs() async throws {
        let server = try PairingServer(code: "482913", guid: "adb-TESTSERIAL-abc123", identity: serverIdentity)
        let port = try await server.start()
        defer { server.stop() }
        let result = try await PairingClient(connector: connector).pair(host: "127.0.0.1", port: port, code: "482913")
        #expect(result.guid == "adb-TESTSERIAL-abc123")
        var iterator = server.pairings.makeAsyncIterator()
        let paired = try #require(await iterator.next()).get()
        #expect(paired.peerInfo.kind == .rsaPublicKey)
        #expect(paired.peerInfo.text == "\(try connector.key.androidPublicKeyBase64()) test@droiddrive")
    }

    @Test("a wrong code fails on both sides")
    func wrongCode() async throws {
        let server = try PairingServer(code: "111111", guid: "adb-X-1", identity: serverIdentity)
        let port = try await server.start()
        defer { server.stop() }
        await #expect(throws: WifiPairingError.wrongCode) {
            _ = try await PairingClient(connector: connector).pair(host: "127.0.0.1", port: port, code: "222222")
        }
        var iterator = server.pairings.makeAsyncIterator()
        let outcome = try #require(await iterator.next())
        #expect(throws: (any Error).self) { try outcome.get() }
    }

    @Test("nothing listening is a disconnect")
    func refused() async throws {
        await #expect(throws: DeviceError.disconnected) {
            _ = try await PairingClient(connector: connector).pair(host: "127.0.0.1", port: 1, code: "1", timeout: 3)
        }
    }
}
