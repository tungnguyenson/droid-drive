import AdbKit
import DroidCore
import Foundation
import Testing
@testable import AdbPairing

@Suite("QR code")
struct QrCodeTests {
    @Test("payload has Android Studio's format and parses back")
    func payload() throws {
        let code = QrPairingCode(serviceName: "droiddrive-abc", password: "s3cret")
        #expect(code.payload == "WIFI:T:ADB;S:droiddrive-abc;P:s3cret;;")
        #expect(QrPairingCode.parse(code.payload) == code)
        #expect(QrPairingCode.parse("WIFI:T:WPA;S:x;P:y;;") == nil)
        #expect(QrPairingCode.parse("WIFI:T:ADB;S:;P:y;;") == nil)
        #expect(QrPairingCode.parse("hello") == nil)
    }

    @Test("random codes are fresh, long enough and need no escaping")
    func random() {
        let a = QrPairingCode.random()
        let b = QrPairingCode.random()
        #expect(a != b)
        #expect(a.serviceName.hasPrefix("droiddrive-") && a.serviceName.count == 21)
        #expect(a.password.count == 12)
        let allowed = Set(QrPairingCode.alphabet)
        #expect(a.password.allSatisfy(allowed.contains))
        #expect(!a.payload.dropFirst(5).dropLast(2).contains("\\"))
    }

    @Test("renders a square image")
    func image() throws {
        let image = try #require(QrPairingCode.random().image(scale: 4))
        #expect(image.width == image.height)
        #expect(image.width >= 21 * 4)
    }
}

@Suite("Paired device store")
struct PairedDeviceStoreTests {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("droiddrive-test-\(UUID().uuidString)/wifi-devices.json")

    @Test("upsert, update, reload from disk, remove")
    func roundTrip() async throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PairedDeviceStore(fileURL: url)
        #expect(try await store.all().isEmpty)
        try await store.upsert(PairedDevice(id: "adb-ABC-1", kind: .paired, lastHost: "10.0.0.2"))
        try await store.upsert(PairedDevice(id: "SERIAL2", serial: "SERIAL2", kind: .tcpip, lastHost: "10.0.0.3", lastPort: 5555))
        try await store.noteConnected(id: "adb-ABC-1", host: "10.0.0.9", port: 41234, serial: "ABC", model: "Pixel")
        try await store.noteConnected(id: "unknown", host: "x", port: 1, serial: nil, model: nil)

        let reloaded = PairedDeviceStore(fileURL: url)
        let device = try #require(try await reloaded.device(id: "adb-ABC-1"))
        #expect(device.lastHost == "10.0.0.9" && device.lastPort == 41234)
        #expect(device.serial == "ABC" && device.model == "Pixel")
        #expect(try await reloaded.all().count == 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        try await reloaded.remove(id: "adb-ABC-1")
        #expect(try await PairedDeviceStore(fileURL: url).all().map(\.id) == ["SERIAL2"])
    }

    @Test("a corrupt file is an error, not an empty list")
    func corrupt() async throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        await #expect(throws: DeviceError.self) { _ = try await PairedDeviceStore(fileURL: url).all() }
    }
}

@Suite("tcpip switch")
struct TcpipSwitchTests {
    @Test("address from `ip addr show wlan0`")
    func ipAddr() {
        let text = """
        16: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
            inet 192.168.5.42/24 brd 192.168.5.255 scope global wlan0
               valid_lft forever preferred_lft forever
        """
        #expect(TcpipSwitch.parseAddress(text) == "192.168.5.42")
    }

    @Test("falls back to the src of a wlan route")
    func route() {
        let text = "Device \"wlan0\" does not exist.\n10.0.2.0/24 dev wlan1 proto kernel scope link src 10.0.2.16\n"
        #expect(TcpipSwitch.parseAddress(text) == "10.0.2.16")
    }

    @Test("no Wi-Fi, loopback and junk give nothing")
    func none() {
        #expect(TcpipSwitch.parseAddress("") == nil)
        #expect(TcpipSwitch.parseAddress("    inet 127.0.0.1/8 scope host lo") == nil)
        #expect(TcpipSwitch.parseAddress("inet 300.1.1.1/24") == nil)
        #expect(TcpipSwitch.parseAddress("default via 10.0.2.2 dev eth0") == nil)
    }
}

@Suite("Wi-Fi sheet model")
@MainActor
struct WifiConnectModelTests {
    @Test("input checks")
    func validation() {
        #expect(WifiConnectModel.isSixDigits("123456"))
        #expect(WifiConnectModel.isSixDigits(" 123456 "))
        #expect(!WifiConnectModel.isSixDigits("12345"))
        #expect(!WifiConnectModel.isSixDigits("12345a"))
        #expect(!WifiConnectModel.isSixDigits("١٢٣٤٥٦")) // non-ASCII digits
        #expect(WifiConnectModel.legacyEndpoint("192.168.1.2")! == ("192.168.1.2", 5555))
        #expect(WifiConnectModel.legacyEndpoint("192.168.1.2:5556")! == ("192.168.1.2", 5556))
        #expect(WifiConnectModel.legacyEndpoint("") == nil)
        #expect(WifiConnectModel.legacyEndpoint("a b") == nil)
    }

    @Test("buttons enable only with valid input")
    func buttons() throws {
        let model = WifiConnectModel(connector: try WifiConnector(key: try AdbKey.generate(), keyName: "t"),
                                     store: PairedDeviceStore(fileURL: URL(fileURLWithPath: "/dev/null/x.json")))
        #expect(!model.canPairManually)
        model.manualAddress = "10.0.0.2:37123"
        model.manualCode = "123456"
        #expect(model.canPairManually)
        #expect(!model.canPairSelected)
        #expect(!model.canConnectLegacy)
        model.legacyAddress = "10.0.0.2"
        #expect(model.canConnectLegacy)
        #expect(model.tab == .qrCode)
        let before = model.qrCode
        model.regenerateQrCode()
        #expect(model.qrCode != before)
        model.stop()
        #expect(WifiConnectModel.Tab.allCases.map(\.title) == ["QR code", "Pairing code", "Manual", "Android 10 and earlier"])
    }

    @Test("error messages are user-facing")
    func messages() {
        #expect(WifiConnectModel.message(for: WifiPairingError.wrongCode).contains("Wrong pairing code"))
        #expect(WifiConnectModel.message(for: DeviceError.disconnected).contains("same Wi-Fi"))
        #expect(WifiConnectModel.message(for: DeviceError.permissionDenied(.root)).contains("Pair it again"))
        #expect(WifiConnectModel.message(for: DeviceError.unsupported("x")) == "x")
    }
}

@Suite("Discovery values")
struct WifiServiceTests {
    @Test("serial hint from adb's service names")
    func serialHint() {
        func service(_ name: String) -> WifiService {
            WifiService(kind: .connect, name: name, domain: "local.", host: nil, port: nil, interfaceIndex: 0)
        }
        #expect(service("adb-R5CT20ABCDE-xYz12a").serialHint == "R5CT20ABCDE")
        #expect(service("adb-EMULATOR36X3X10X0-UAMfei").serialHint == "EMULATOR36X3X10X0")
        #expect(service("droiddrive-abc").serialHint == nil)
        #expect(service("adb-").serialHint == nil)
        #expect(service("adb-x").id == "_adb-tls-connect._tcp/adb-x")
    }
}

@Suite("Reconnector")
struct WifiReconnectorTests {
    @Test("connects only phones in the store, and reports failures")
    func reconnect() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("droiddrive-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PairedDeviceStore(fileURL: url)
        try await store.upsert(PairedDevice(id: "adb-KNOWN-1", kind: .paired))
        let connector = try WifiConnector(key: try AdbKey.generate(), keyName: "t")
        let snapshot = [
            WifiService(kind: .connect, name: "adb-STRANGER-2", domain: "local.", host: "127.0.0.1", port: 1, interfaceIndex: 0),
            WifiService(kind: .connect, name: "adb-KNOWN-1", domain: "local.", host: "127.0.0.1", port: 1, interfaceIndex: 0),
        ]
        let reconnector = WifiReconnector(store: store, connector: connector, tcpipRetryInterval: .seconds(3600),
                                          discovery: { AsyncStream { $0.yield(snapshot) } })
        await reconnector.start()
        var iterator = reconnector.events.makeAsyncIterator()
        let event = try #require(await iterator.next())
        guard case .failed(let device, let error) = event else {
            Issue.record("expected a failure, got \(event)")
            return
        }
        #expect(device.id == "adb-KNOWN-1")
        #expect(error as? DeviceError == .disconnected)
        await reconnector.stop()
    }
}

/// Runs only with a real wireless-debugging port, e.g. the emulator's forwarded with
/// `adb -s emulator-5554 forward tcp:46001 tcp:<port>` and
/// `DROIDDRIVE_WIFI_TLS=127.0.0.1:46001`. Uses ~/.android/adbkey, which the phone must trust.
@Suite("Wi-Fi integration", .enabled(if: ProcessInfo.processInfo.environment["DROIDDRIVE_WIFI_TLS"] != nil))
struct WifiIntegrationTests {
    @Test("STLS + TLS 1.3 connect, then list a folder")
    func tlsConnect() async throws {
        let address = try PairingClient.parseAddress(ProcessInfo.processInfo.environment["DROIDDRIVE_WIFI_TLS"]!)
        let pem = try String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".android/adbkey"), encoding: .utf8)
        let connector = try WifiConnector(key: try AdbKey(pem: pem))
        let transport = try await connector.transport(host: address.host, port: address.port)
        #expect(!transport.info.serial.isEmpty)
        var names: [String] = []
        for try await batch in transport.list(RemotePath(exact: "/storage/emulated/0")) { names += batch.map(\.path.name) }
        #expect(names.contains("Download"))
    }

    @Test("the reconnector connects a stored phone it sees advertised")
    func reconnects() async throws {
        let address = try PairingClient.parseAddress(ProcessInfo.processInfo.environment["DROIDDRIVE_WIFI_TLS"]!)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("droiddrive-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PairedDeviceStore(fileURL: url)
        try await store.upsert(PairedDevice(id: "adb-TEST-guid", kind: .paired))
        let pem = try String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".android/adbkey"), encoding: .utf8)
        let service = WifiService(kind: .connect, name: "adb-TEST-guid", domain: "local.",
                                  host: address.host, port: address.port, interfaceIndex: 0)
        let reconnector = WifiReconnector(store: store, connector: try WifiConnector(key: try AdbKey(pem: pem)),
                                          tcpipRetryInterval: .seconds(3600),
                                          discovery: { AsyncStream { $0.yield([service]) } })
        await reconnector.start()
        var iterator = reconnector.events.makeAsyncIterator()
        guard case .connected(let device, let transport) = try #require(await iterator.next()) else {
            Issue.record("expected a connection")
            return
        }
        #expect(device.id == "adb-TEST-guid")
        #expect(try await store.device(id: "adb-TEST-guid")?.serial == transport.info.serial)
        await reconnector.stop()
    }
}
