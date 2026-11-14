import DroidCore
import Foundation
import Security
import Testing
@testable import AdbKit

/// A scripted adbd on the far end of an in-memory link. Knows one trusted key, offers
/// an `echo:` service that sends every WRTE back, and refuses everything else.
actor FakeAdbd: AdbPacketLink {
    private let trustedKey: SecKey?
    private let approveNewKeys: Bool
    private var outbox: [AdbMessage] = []
    private var waiter: CheckedContinuation<AdbMessage, Error>?
    private var token = Data()
    private var nextRemoteId: UInt32 = 100
    private var streams: [UInt32: UInt32] = [:] // remote id -> host id
    /// Echo data waiting to go back, per remote id. Like real adbd, at most one WRTE per
    /// stream is in flight until the host OKAYs it.
    private var echoQueue: [UInt32: [Data]] = [:]
    private var inFlight: Set<UInt32> = []
    private(set) var receivedPublicKey: String?
    /// OKAYs from the host for which no device WRTE was outstanding.
    private(set) var spuriousAcks = 0

    init(trustedKey: SecKey?, approveNewKeys: Bool = false) {
        self.trustedKey = trustedKey
        self.approveNewKeys = approveNewKeys
    }

    func send(_ message: AdbMessage) async throws {
        switch message.command {
        case .cnxn:
            token = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
            deliver(AdbMessage(.auth, 1, 0, token))
        case .auth where message.arg0 == 2:
            var error: Unmanaged<CFError>?
            let ok = trustedKey.map {
                SecKeyVerifySignature($0, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, message.payload as CFData, &error)
            } ?? false
            deliver(ok ? connected() : AdbMessage(.auth, 1, 0, token))
        case .auth where message.arg0 == 3:
            receivedPublicKey = String(decoding: message.payload.dropLast(), as: UTF8.self)
            if approveNewKeys { deliver(connected()) }
        case .open:
            let service = String(decoding: message.payload.dropLast(), as: UTF8.self)
            if service == "echo:" {
                let remote = nextRemoteId
                nextRemoteId += 1
                streams[remote] = message.arg0
                deliver(AdbMessage(.okay, remote, message.arg0))
            } else {
                deliver(AdbMessage(.clse, 0, message.arg0))
            }
        case .wrte:
            let remote = message.arg1
            guard let host = streams[remote] else { return }
            deliver(AdbMessage(.okay, remote, host))
            echoQueue[remote, default: []].append(message.payload)
            sendNextEcho(remote)
        case .okay:
            let remote = message.arg1
            if inFlight.remove(remote) == nil { spuriousAcks += 1 }
            sendNextEcho(remote)
        default:
            break
        }
    }

    func setChecksumRequired(_ required: Bool) {}

    func receive() async throws -> AdbMessage {
        if !outbox.isEmpty { return outbox.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() async { dropLink() }

    /// Simulates pulling the cable: the pending receive fails.
    func dropLink() {
        waiter?.resume(throwing: DeviceError.disconnected)
        waiter = nil
    }

    private func sendNextEcho(_ remote: UInt32) {
        guard !inFlight.contains(remote), let host = streams[remote],
              var queue = echoQueue[remote], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        echoQueue[remote] = queue
        inFlight.insert(remote)
        deliver(AdbMessage(.wrte, remote, host, next))
    }

    private func connected() -> AdbMessage {
        AdbMessage(.cnxn, AdbMessage.version, 4096, Data("device::ro.product.model=Fake;features=shell_v2,ls_v2,stat_v2".utf8))
    }

    private func deliver(_ message: AdbMessage) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            outbox.append(message)
        }
    }
}

@Suite("ADB connection")
struct AdbConnectionTests {
    let key: AdbKey

    init() throws { key = try AdbKey.generate() }

    @Test("trusted key connects with a signature, no prompt")
    func trustedKey() async throws {
        let device = FakeAdbd(trustedKey: key.publicKey)
        let events = EventLog()
        let connection = try await AdbConnection.connect(link: device, key: key, keyName: "t@mac") { events.add($0) }
        #expect(connection.banner.properties["ro.product.model"] == "Fake")
        #expect(connection.features.contains("ls_v2"))
        #expect(connection.maxPayload == 4096)
        #expect(events.count == 0)
        #expect(await device.receivedPublicKey == nil)
        await connection.close()
    }

    @Test("unknown key sends the public key and waits for the user")
    func unknownKey() async throws {
        let device = FakeAdbd(trustedKey: nil, approveNewKeys: true)
        let events = EventLog()
        let connection = try await AdbConnection.connect(link: device, key: key, keyName: "t@mac") { events.add($0) }
        #expect(events.count == 1)
        let sent = await device.receivedPublicKey
        #expect(sent == "\(try key.androidPublicKeyBase64()) t@mac")
        await connection.close()
    }

    @Test("approval timeout fails instead of hanging")
    func approvalTimeout() async throws {
        let device = FakeAdbd(trustedKey: nil, approveNewKeys: false)
        await #expect(throws: DeviceError.disconnected) {
            _ = try await AdbConnection.connect(link: device, key: key, keyName: "t", approvalTimeout: .milliseconds(200))
        }
    }

    @Test("a large write is split at max payload and echoed back in order")
    func echoes() async throws {
        let device = FakeAdbd(trustedKey: key.publicKey)
        let connection = try await AdbConnection.connect(link: device, key: key, keyName: "t")
        let stream = try await connection.open("echo:")
        let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        async let written: Void = stream.write(payload)
        var received = Data()
        while received.count < payload.count {
            guard let chunk = try await stream.read() else { break }
            #expect(chunk.count <= 4096)
            received.append(chunk)
        }
        try await written
        #expect(received == payload)
        #expect(await device.spuriousAcks == 0, "host must OKAY only device WRTEs it consumed")
        await stream.close()
        await connection.close()
    }

    @Test("streams are independent")
    func multiplexes() async throws {
        let device = FakeAdbd(trustedKey: key.publicKey)
        let connection = try await AdbConnection.connect(link: device, key: key, keyName: "t")
        let a = try await connection.open("echo:")
        let b = try await connection.open("echo:")
        try await b.write(Data("bee".utf8))
        try await a.write(Data("ay".utf8))
        #expect(try await a.read() == Data("ay".utf8))
        #expect(try await b.read() == Data("bee".utf8))
        await connection.close()
    }

    @Test("a refused service fails open")
    func refused() async throws {
        let device = FakeAdbd(trustedKey: key.publicKey)
        let connection = try await AdbConnection.connect(link: device, key: key, keyName: "t")
        await #expect(throws: DeviceError.self) { _ = try await connection.open("nope:") }
        await connection.close()
    }

    @Test("dropping the link fails pending reads with disconnected")
    func linkDrop() async throws {
        let device = FakeAdbd(trustedKey: key.publicKey)
        let connection = try await AdbConnection.connect(link: device, key: key, keyName: "t")
        let stream = try await connection.open("echo:")
        let pending = Task { try await stream.read() }
        try await Task.sleep(for: .milliseconds(50))
        await device.dropLink()
        await #expect(throws: DeviceError.disconnected) { _ = try await pending.value }
        await #expect(throws: DeviceError.disconnected) { _ = try await connection.open("echo:") }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AdbConnection.AuthEvent] = []
    func add(_ event: AdbConnection.AuthEvent) { lock.withLock { events.append(event) } }
    var count: Int { lock.withLock { events.count } }
}
