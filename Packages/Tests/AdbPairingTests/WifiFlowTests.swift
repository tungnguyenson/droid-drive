import AdbKit
import DroidCore
import Foundation
import SwiftUI
import Testing
@testable import AdbPairing

/// An adb server-style opener with canned answers: legacy `shell:` (no shell_v2) and
/// the `tcpip:` service.
struct CannedOpener: AdbServiceOpener {
    let shellOutput: String
    let tcpipReply: String
    var features: Set<String> { [] }

    func open(_ service: String) async throws -> any AdbByteStream {
        if service.hasPrefix("shell:") { return CannedStream(Data((shellOutput + "\u{1F}DDEXIT:0").utf8)) }
        if service.hasPrefix("tcpip:") { return CannedStream(Data(tcpipReply.utf8)) }
        throw DeviceError.protocolError("refused \(service)")
    }
}

final class CannedStream: AdbByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Data?
    init(_ data: Data) { pending = data }
    func write(_ data: Data) async throws {}
    func read() async throws -> Data? { lock.withLock { defer { pending = nil }; return pending } }
    func close() async {}
}

@Suite("tcpip switch with a fake phone")
struct TcpipFlowTests {
    @Test("reads the Wi-Fi address and accepts adbd's restart reply")
    func addressAndEnable() async throws {
        let opener = CannedOpener(shellOutput: "    inet 192.168.5.42/24 brd 192.168.5.255 scope global wlan0\n",
                                  tcpipReply: "restarting in TCP mode port: 5555\n")
        #expect(try await TcpipSwitch.wifiAddress(on: opener) == "192.168.5.42")
        try await TcpipSwitch.enable(on: opener)
    }

    @Test("no Wi-Fi and a refused switch are errors")
    func failures() async throws {
        let opener = CannedOpener(shellOutput: "", tcpipReply: "error: not allowed\n")
        await #expect(throws: DeviceError.unsupported("The phone is not on Wi-Fi")) {
            _ = try await TcpipSwitch.wifiAddress(on: opener)
        }
        await #expect(throws: DeviceError.self) { try await TcpipSwitch.enable(on: opener) }
        let connector = try WifiConnector(key: try AdbKey.generate(), keyName: "t")
        await #expect(throws: DeviceError.self) {
            _ = try await TcpipSwitch.switchToWifi(opener: opener, serial: "S", connector: connector)
        }
    }
}

@Suite("Wi-Fi sheet flows", .serialized)
@MainActor
struct WifiSheetFlowTests {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("droiddrive-\(UUID().uuidString).json")

    func settle(_ model: WifiConnectModel) async {
        for _ in 0..<200 where model.isWorking || model.status == .idle {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("manual pairing stores the phone; connect failure still reports the pairing")
    func manualPairing() async throws {
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let server = try PairingServer(code: "135790", guid: "adb-MANUAL-1", identity: try TlsIdentity(key: try AdbKey.generate()))
        let port = try await server.start()
        defer { server.stop() }
        let store = PairedDeviceStore(fileURL: storeURL)
        let model = WifiConnectModel(connector: try WifiConnector(key: try AdbKey.generate(), keyName: "t"), store: store)
        model.manualAddress = "127.0.0.1:\(port)"
        model.manualCode = "135790"
        model.manualConnectAddress = "127.0.0.1:1"
        model.pairManually()
        #expect(model.isWorking)
        await settle(model)
        guard case .succeeded(let text) = model.status else {
            Issue.record("unexpected status \(model.status)")
            return
        }
        #expect(text.hasPrefix("Paired."))
        #expect(try await store.device(id: "adb-MANUAL-1")?.kind == .paired)
    }

    @Test("a wrong code shows the wrong-code message")
    func wrongCode() async throws {
        let server = try PairingServer(code: "111111", guid: "adb-X-1", identity: try TlsIdentity(key: try AdbKey.generate()))
        let port = try await server.start()
        defer { server.stop() }
        let model = WifiConnectModel(connector: try WifiConnector(key: try AdbKey.generate(), keyName: "t"),
                                     store: PairedDeviceStore(fileURL: storeURL))
        model.manualAddress = "127.0.0.1:\(port)"
        model.manualCode = "222222"
        model.pairManually()
        await settle(model)
        #expect(model.status == .failed(WifiPairingError.wrongCode.errorDescription!))
    }

    @Test("legacy connect to nothing fails with a network hint")
    func legacyFailure() async throws {
        let model = WifiConnectModel(connector: try WifiConnector(key: try AdbKey.generate(), keyName: "t"),
                                     store: PairedDeviceStore(fileURL: storeURL))
        model.legacyAddress = "127.0.0.1:1"
        model.connectLegacy()
        await settle(model)
        #expect(model.status == .failed(WifiConnectModel.message(for: DeviceError.disconnected)))
    }

    /// Renders every tab, so the views at least build their bodies. With
    /// `DROIDDRIVE_SNAPSHOT_DIR` set, writes PNGs there for a look.
    @Test("every tab renders")
    func renders() throws {
        let model = WifiConnectModel(connector: try WifiConnector(key: try AdbKey.generate(), keyName: "t"),
                                     store: PairedDeviceStore(fileURL: storeURL))
        let statuses: [WifiConnectModel.Status] = [.idle, .working("Pairing…"), .succeeded("Connected."), .failed("Nope.")]
        for (index, tab) in WifiConnectModel.Tab.allCases.enumerated() {
            model.tab = tab
            let view = ConnectViaWifiSheet(model: model, onClose: {})
                .overlay(alignment: .bottomLeading) { StatusLine(status: statuses[index]).padding(20) }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width >= 1000)
            if let dir = ProcessInfo.processInfo.environment["DROIDDRIVE_SNAPSHOT_DIR"],
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("wifi-\(index).png"))
            }
        }
    }
}
