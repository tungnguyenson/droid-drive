import AdbKit
import Foundation
import Testing
@testable import AdbPairing

/// QR pairing end to end through real mDNS on this Mac (plans P3-04, P3-06): our
/// `PairingServer` plays the phone, and `dns-sd -P` advertises it under the QR's
/// service name the way a phone does after scanning. Opt-in, because it registers a
/// Bonjour service on the local network for a few seconds: `DROIDDRIVE_MDNS_TEST=1`.
@Suite("QR pairing over mDNS", .enabled(if: ProcessInfo.processInfo.environment["DROIDDRIVE_MDNS_TEST"] != nil))
struct QrMdnsTests {
    @Test("the client finds the scanned code's service, resolves it and pairs")
    func qrPairing() async throws {
        let code = QrPairingCode.random()
        let server = try PairingServer(code: code.password, guid: "adb-QRTEST-123456",
                                       identity: try TlsIdentity(key: try AdbKey.generate()))
        let port = try await server.start()
        defer { server.stop() }

        let advert = Process()
        advert.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        advert.arguments = ["-P", code.serviceName, WifiService.Kind.pairing.rawValue, "local", String(port),
                            "droiddrive-qrtest.local", "127.0.0.1"]
        advert.standardOutput = FileHandle.nullDevice
        try advert.run()
        defer { advert.terminate() }

        let connector = try WifiConnector(key: try AdbKey.generate(), keyName: "qr@test")
        let result = try await PairingClient(connector: connector).pair(qr: code, timeout: .seconds(20))
        #expect(result.guid == "adb-QRTEST-123456")
        #expect(result.host == "127.0.0.1" && result.port == port)
    }
}
