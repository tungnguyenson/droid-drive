import DroidCore
import Foundation
import Testing
@testable import AdbKit

private func device(_ serial: String, _ state: String = "device", model: String = "Pixel_8") -> AdbServerClient.Device {
    AdbServerClient.Device(serial: serial, state: state, properties: ["model": model])
}

/// Counts identity reads so the cache can be checked.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("Device identity")
struct DeviceIdentityTests {
    @Test("reads serial and android_id")
    func parsesBoth() {
        let id = DeviceIdentity.parse("R5CT20ABCDE\nf48c23b15dc4073a\n", adbSerial: "192.168.1.23:41234")
        #expect(id == DeviceIdentity(serial: "R5CT20ABCDE", androidId: "f48c23b15dc4073a"))
    }

    @Test("falls back to the adb serial when the phone reports no serial")
    func emptySerial() {
        let id = DeviceIdentity.parse("\nnull\n", adbSerial: "emulator-5554")
        #expect(id == DeviceIdentity(serial: "emulator-5554", androidId: ""))
    }

    @Test("Wi-Fi serials are recognised", arguments: [
        ("192.168.1.23:41234", true),
        ("[fe80::1]:5555", true),
        ("adb-R5CT20ABCDE-xYz12a._adb-tls-connect._tcp", true),
        ("R5CT20ABCDE", false),
        ("emulator-5554", false),
    ])
    func network(serial: String, expected: Bool) {
        #expect(DeviceDirectory.isWiFi(serial) == expected)
    }
}

@Suite("Device directory")
struct DeviceDirectoryTests {
    let pixel = DeviceIdentity(serial: "R5CT20ABCDE", androidId: "aaaa")

    @Test("USB and Wi-Fi connections of one phone are one phone, USB preferred")
    func groupsByIdentity() {
        let phones = DeviceDirectory.group(
            [device("192.168.1.23:41234"), device("R5CT20ABCDE")],
            identities: ["192.168.1.23:41234": pixel, "R5CT20ABCDE": pixel])
        #expect(phones == [Phone(id: "R5CT20ABCDE", model: "Pixel 8", state: .ready, adbSerial: "R5CT20ABCDE",
                                 adbSerials: ["192.168.1.23:41234", "R5CT20ABCDE"])])
    }

    @Test("a new Wi-Fi port keeps the same phone id")
    func portChange() {
        let before = DeviceDirectory.group([device("192.168.1.23:41234")], identities: ["192.168.1.23:41234": pixel])
        let after = DeviceDirectory.group([device("192.168.1.23:39001")], identities: ["192.168.1.23:39001": pixel])
        #expect(before.map(\.id) == ["R5CT20ABCDE"])
        #expect(after.map(\.id) == ["R5CT20ABCDE"])
        #expect(after.first?.adbSerial == "192.168.1.23:39001")
    }

    @Test("two phones with the same serial are a conflict, not one phone")
    func sameSerialDifferentPhones() {
        let a = DeviceIdentity(serial: "0123456789ABCDEF", androidId: "1111")
        let b = DeviceIdentity(serial: "0123456789ABCDEF", androidId: "2222")
        let phones = DeviceDirectory.group([device("0123456789ABCDEF"), device("10.0.0.5:5555")],
                                           identities: ["0123456789ABCDEF": a, "10.0.0.5:5555": b])
        #expect(phones.count == 1)
        #expect(phones.first?.state == .conflict)
        #expect(phones.first?.adbSerial == nil)
    }

    @Test("phones not yet identified keep their adb serial and state")
    func unidentified() {
        let phones = DeviceDirectory.group([device("ABC", "unauthorized"), device("DEF", "offline"), device("GHI")],
                                           identities: [:])
        #expect(phones.map(\.id) == ["ABC", "DEF", "GHI"])
        #expect(phones.map(\.state) == [.unauthorized, .offline, .offline])
    }

    @Test("an unauthorized USB link joins the same phone's ready Wi-Fi link, which is used")
    func mixedStates() {
        let phones = DeviceDirectory.group([device("R5CT20ABCDE", "unauthorized"), device("192.168.1.23:41234")],
                                           identities: ["192.168.1.23:41234": pixel])
        #expect(phones.map(\.state) == [.ready])
        #expect(phones.first?.adbSerial == "192.168.1.23:41234")
    }

    @Test("identities are read once per connection and forgotten when it goes away")
    func caches() async throws {
        let reads = Reads()
        let current = Reads()   // 0: USB only, 1: Wi-Fi only
        let directory = DeviceDirectory(
            listDevices: { current.value == 0 ? [device("R5CT20ABCDE")] : [device("192.168.1.23:41234")] },
            readIdentity: { [pixel] _ in reads.add(); return pixel })
        _ = try await directory.phones()
        _ = try await directory.phones()
        #expect(reads.value == 1)
        current.add()
        #expect(try await directory.adbSerial(for: "R5CT20ABCDE") == "192.168.1.23:41234")
        #expect(reads.value == 2)
    }

    @Test("resolving a phone that is not connected throws disconnected")
    func missing() async {
        let directory = DeviceDirectory(listDevices: { [] }, readIdentity: { _ in throw DeviceError.disconnected })
        await #expect(throws: DeviceError.disconnected) { try await directory.adbSerial(for: "R5CT20ABCDE") }
    }

    @Test("resolving a conflicting serial throws busy")
    func conflictThrows() async {
        let directory = DeviceDirectory(
            listDevices: { [device("X"), device("10.0.0.5:5555")] },
            readIdentity: { serial in DeviceIdentity(serial: "X", androidId: serial) })
        await #expect(throws: DeviceError.busy(by: "another phone with the same serial number")) { try await directory.adbSerial(for: "X") }
    }

    @Test("an identity that cannot be read yet shows the phone offline and retries")
    func unreadable() async throws {
        let reads = Reads()
        let directory = DeviceDirectory(
            listDevices: { [device("R5CT20ABCDE")] },
            readIdentity: { [pixel] _ in
                reads.add()
                if reads.value == 1 { throw DeviceError.disconnected }
                return pixel
            })
        #expect(try await directory.phones().first?.state == .offline)
        #expect(try await directory.phones().first?.state == .ready)
    }
}
