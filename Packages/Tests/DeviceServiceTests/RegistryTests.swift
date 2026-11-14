import AdbKit
import DroidCore
import Foundation
import Testing
@testable import DeviceService

@Suite("Device registry and sources")
struct RegistryTests {
    @Test("one phone seen by two sources is one row, ADB over USB preferred")
    func mergePrefersUsbAdb() async throws {
        let wifi = ScriptedSource(id: "wifi", phones: [phone("P1", .adbWiFi)])
        let mtp = ScriptedSource(id: "mtp", phones: [phone("P1", .mtpUSB)])
        let usb = ScriptedSource(id: "usb", phones: [phone("P1", .adbUSB)])
        let registry = DeviceRegistry(sources: [wifi, mtp, usb])
        let snapshot = await registry.refresh()
        #expect(snapshot.phones.count == 1)
        #expect(snapshot.phones[0].sourceId == "usb")
        #expect(snapshot.phones[0].connections == [.adbUSB, .adbWiFi, .mtpUSB])
    }

    @Test("MTP wins when the user prefers it")
    func preferMTP() async throws {
        let usb = ScriptedSource(id: "usb", phones: [phone("P1", .adbUSB)])
        let mtp = ScriptedSource(id: "mtp", phones: [phone("P1", .mtpUSB)])
        let registry = DeviceRegistry(sources: [usb, mtp], preferMTP: true)
        #expect(await registry.refresh().phones[0].phone.connection == .mtpUSB)
        await registry.setPreferMTP(false)
        #expect(await registry.refresh().phones[0].phone.connection == .adbUSB)
    }

    @Test("a ready connection beats a preferred one that is not ready")
    func readyFirst() async throws {
        let usb = ScriptedSource(id: "usb", phones: [phone("P1", .adbUSB, .unauthorized)])
        let wifi = ScriptedSource(id: "wifi", phones: [phone("P1", .adbWiFi)])
        let registry = DeviceRegistry(sources: [usb, wifi])
        #expect(await registry.refresh().phones[0].phone.connection == .adbWiFi)
    }

    @Test("a conflict reported by any source marks the phone as conflict")
    func conflictWins() async throws {
        let usb = ScriptedSource(id: "usb", phones: [phone("P1", .adbUSB)])
        let wifi = ScriptedSource(id: "wifi", phones: [phone("P1", .adbWiFi, .conflict)])
        let registry = DeviceRegistry(sources: [usb, wifi])
        #expect(await registry.refresh().phones[0].phone.state == .conflict)
        await #expect(throws: DeviceError.busy(by: "another phone with the same serial number")) {
            _ = try await registry.transport(for: "P1")
        }
    }

    @Test("states other than ready give no transport", arguments: [PhoneState.unauthorized, .offline])
    func notReady(_ state: PhoneState) async throws {
        let registry = DeviceRegistry(sources: [ScriptedSource(id: "s", phones: [phone("P1", .adbUSB, state)])])
        await registry.refresh()
        await #expect(throws: DeviceError.disconnected) { _ = try await registry.transport(for: "P1") }
    }

    @Test("a busy USB interface reports who holds it")
    func busy() async throws {
        let registry = DeviceRegistry(sources: [ScriptedSource(id: "s", phones: [phone("P1", .mtpUSB, .busy(by: "ptpcamerad"))])])
        await registry.refresh()
        await #expect(throws: DeviceError.busy(by: "ptpcamerad")) { _ = try await registry.transport(for: "P1") }
    }

    @Test("transports are cached, and reopened after invalidate or a connection change")
    func caching() async throws {
        let source = ScriptedSource(id: "s", phones: [phone("P1", .adbUSB, address: "A")])
        let registry = DeviceRegistry(sources: [source])
        await registry.refresh()
        _ = try await registry.transport(for: "P1")
        _ = try await registry.transport(for: "P1")
        #expect(source.openCount == 1)
        await registry.invalidate(phoneId: "P1")
        _ = try await registry.transport(for: "P1")
        #expect(source.openCount == 2)
        source.set([phone("P1", .adbUSB, address: "B")])
        await registry.refresh()
        _ = try await registry.transport(for: "P1")
        #expect(source.openCount == 3)
    }

    @Test("concurrent requests open one transport")
    func concurrentOpen() async throws {
        let source = ScriptedSource(id: "s", phones: [phone("P1")])
        let registry = DeviceRegistry(sources: [source])
        await registry.refresh()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await registry.transport(for: "P1") } }
            try await group.waitForAll()
        }
        #expect(source.openCount == 1)
    }

    @Test("a transport to a different phone is refused")
    func serialMismatch() async throws {
        let source = ScriptedSource(id: "s", phones: [phone("P1")])
        source.transportSerial = "SOMEONE-ELSE"
        let registry = DeviceRegistry(sources: [source])
        await registry.refresh()
        await #expect(throws: DeviceError.disconnected) { _ = try await registry.transport(for: "P1") }
    }

    @Test("an unknown phone triggers one rescan before giving up")
    func unknownRescans() async throws {
        let source = ScriptedSource(id: "s")
        let registry = DeviceRegistry(sources: [source])
        await registry.refresh()
        source.set([phone("P1")])
        _ = try await registry.transport(for: "P1")
        source.set([])
        await registry.refresh()
        await #expect(throws: DeviceError.disconnected) { _ = try await registry.transport(for: "P1") }
    }

    @Test("a failing source is reported; the others still count")
    func failingSource() async throws {
        let broken = ScriptedSource(id: "adb-server")
        broken.fail(DeviceError.disconnected)
        let ok = ScriptedSource(id: "usb", phones: [phone("P1")])
        let snapshot = await DeviceRegistry(sources: [broken, ok]).refresh()
        #expect(snapshot.phones.map(\.id) == ["P1"])
        #expect(snapshot.failedSources.keys.sorted() == ["adb-server"])
    }

    @Test("adb server phones map to connection kinds by their adb serial")
    func adbMapping() {
        let usb = AdbServerSource.discovered(id: "R5CT", model: "SM-S918B", state: .ready,
                                             adbSerial: "R5CT", adbSerials: ["R5CT"])
        #expect(usb.connection == .adbUSB)
        #expect(usb.address == "R5CT")
        let wifi = AdbServerSource.discovered(id: "R5CT", model: "x", state: .ready,
                                              adbSerial: "192.168.1.5:41234", adbSerials: ["192.168.1.5:41234"])
        #expect(wifi.connection == .adbWiFi)
        let waiting = AdbServerSource.discovered(id: "emulator-5554", model: "x", state: .unauthorized,
                                                 adbSerial: nil, adbSerials: ["emulator-5554"])
        #expect(waiting.state == .unauthorized)
        #expect(waiting.address == "emulator-5554")
        #expect(AdbServerSource.discovered(id: "a", model: "x", state: .offline, adbSerial: nil, adbSerials: []).state == .offline)
        #expect(AdbServerSource.discovered(id: "a", model: "x", state: .conflict, adbSerial: nil, adbSerials: []).address == "a")
    }

    @Test("connection labels")
    func labels() {
        #expect(ConnectionKind.adbUSB.label == "ADB · USB")
        #expect(ConnectionKind.adbWiFi.label == "ADB · Wi-Fi")
        #expect(ConnectionKind.mtpUSB.label == "MTP · USB")
    }

    @Test("the adb server source reports a stopped server as an error")
    func adbServerDown() async throws {
        // Port 9 (discard) has nothing listening on a normal Mac.
        let source = AdbServerSource(server: AdbServerClient(host: "127.0.0.1", port: 9))
        await #expect(throws: (any Error).self) { _ = try await source.scan() }
    }
}
