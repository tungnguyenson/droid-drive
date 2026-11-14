import DroidCore
import Foundation
import Testing
@testable import AdbKit

/// adbd's wireless-debugging port as a scripted link: answers CNXN with STLS, expects
/// our STLS back, then (after `startTls`) sends CNXN. Never sends AUTH.
actor FakeTlsAdbd: AdbTlsUpgradable {
    enum Behaviour { case normal, rejectCertificate, stlsTwice, noUpgradeSupport }

    private let behaviour: Behaviour
    private var outbox: [AdbMessage] = []
    private var waiter: CheckedContinuation<AdbMessage, Error>?
    private(set) var log: [String] = []

    init(_ behaviour: Behaviour = .normal) { self.behaviour = behaviour }

    func send(_ message: AdbMessage) async throws {
        switch message.command {
        case .cnxn:
            log.append("cnxn")
            deliver(AdbMessage(.stls, AdbMessage.stlsVersion, 0))
        case .stls:
            log.append("stls \(String(format: "%08x", message.arg0))")
        default:
            log.append("\(message.command)")
        }
    }

    func startTls() async throws {
        guard log.last?.hasPrefix("stls") == true else { throw DeviceError.protocolError("TLS before STLS") }
        log.append("tls")
        switch behaviour {
        case .rejectCertificate:
            throw DeviceError.permissionDenied(.root)
        case .stlsTwice:
            deliver(AdbMessage(.stls, AdbMessage.stlsVersion, 0))
        default:
            deliver(AdbMessage(.cnxn, AdbMessage.version, 1 << 20,
                               Data("device::ro.product.model=WifiPhone;features=shell_v2,ls_v2".utf8)))
        }
    }

    func setChecksumRequired(_ required: Bool) { log.append("checksum \(required)") }

    func receive() async throws -> AdbMessage {
        if !outbox.isEmpty { return outbox.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() async {
        waiter?.resume(throwing: DeviceError.disconnected)
        waiter = nil
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

/// A link that cannot do TLS (like `TcpPacketLink`), facing a TLS-only adbd.
actor PlainLinkToTlsAdbd: AdbPacketLink {
    private var pending: AdbMessage?
    func send(_ message: AdbMessage) async throws {
        if message.command == .cnxn { pending = AdbMessage(.stls, AdbMessage.stlsVersion, 0) }
    }
    func setChecksumRequired(_ required: Bool) {}
    func receive() async throws -> AdbMessage {
        guard let pending else { throw DeviceError.disconnected }
        self.pending = nil
        return pending
    }
    func close() async {}
}

@Suite("STLS upgrade")
struct TlsStlsTests {
    let key: AdbKey
    init() throws { key = try AdbKey.generate() }

    @Test("CNXN, STLS, our STLS reply, TLS, then the device's CNXN")
    func upgrade() async throws {
        let device = FakeTlsAdbd()
        let connection = try await AdbConnection.connect(link: device, key: key, keyName: "t@mac")
        #expect(connection.banner.properties["ro.product.model"] == "WifiPhone")
        #expect(connection.features.contains("ls_v2"))
        #expect(await device.log == ["cnxn", "stls 01000000", "tls", "checksum false"])
        await connection.close()
    }

    @Test("a link without TLS still reports unsupported")
    func plainLink() async throws {
        await #expect(throws: DeviceError.unsupported("The device requires TLS (Wi-Fi pairing)")) {
            _ = try await AdbConnection.connect(link: PlainLinkToTlsAdbd(), key: key, keyName: "t@mac")
        }
    }

    @Test("a phone that rejects our certificate is permissionDenied, not a dropped link")
    func rejected() async throws {
        await #expect(throws: DeviceError.permissionDenied(.root)) {
            _ = try await AdbConnection.connect(link: FakeTlsAdbd(.rejectCertificate), key: key, keyName: "t@mac")
        }
    }

    @Test("a second STLS is refused")
    func twice() async throws {
        await #expect(throws: DeviceError.self) {
            _ = try await AdbConnection.connect(link: FakeTlsAdbd(.stlsTwice), key: key, keyName: "t@mac")
        }
    }
}
