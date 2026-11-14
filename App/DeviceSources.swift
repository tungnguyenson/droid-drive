import AdbKit
import AdbPairing
import DeviceService
import DroidCore
import Foundation
import MtpKit
import os
import UsbKit

private let log = Logger(subsystem: "com.droiddrive.app", category: "sources")

/// DroidDrive's own ADB key, from the Keychain (plan P1-05). Loaded on first use, since
/// creating a key takes a moment and only USB/Wi-Fi connections of DroidDrive's own need it.
actor AdbKeyProvider {
    static let shared = AdbKeyProvider()
    private var key: AdbKey?
    private var connector: WifiConnector?

    func adbKey() throws -> AdbKey {
        if let key { return key }
        let loaded = try AdbKeyStore().loadOrCreate()
        key = loaded
        return loaded
    }

    func wifiConnector() throws -> WifiConnector {
        if let connector { return connector }
        let made = try WifiConnector(key: adbKey())
        connector = made
        return made
    }

    static var keyName: String { "droiddrive@\(ProcessInfo.processInfo.hostName)" }
}

/// ADB over USB without the adb server (plan P1-03, spec §5.4). When the user's adb
/// server runs, it holds the ADB interface and `AdbServerSource` reaches the phone
/// through it, so this source stays out of the way.
struct UsbAdbSource: DeviceSource {
    let id = "usb-adb"
    private let server = AdbServerClient()

    func scan() async throws -> [DiscoveredPhone] {
        if await server.isRunning() { return [] }
        return UsbRegistry.devices().compactMap { device in
            guard let interface = device.adbInterface else { return nil }
            return DiscoveredPhone(id: Self.phoneId(device), model: device.displayName, connection: .adbUSB,
                                   state: Self.state(of: interface), address: String(interface.registryID))
        }
    }

    func makeTransport(for phone: DiscoveredPhone) async throws -> any DeviceTransport {
        guard let registryID = UInt64(phone.address) else { throw DeviceError.disconnected }
        let channels: UsbInterfaceChannels
        do {
            channels = try UsbInterfaceOpener.open(registryID: registryID)
        } catch {
            throw Self.deviceError(error)
        }
        let link = UsbPacketLink(channels: channels)
        let connection = try await AdbConnection.connect(link: link, key: try await AdbKeyProvider.shared.adbKey(),
                                                         keyName: AdbKeyProvider.keyName)
        return try await AdbTransport.connect(connection, fallbackSerial: phone.id)
    }

    /// The USB serial is `ro.serialno` on Android; fall back to the port.
    static func phoneId(_ device: UsbDeviceInfo) -> String {
        device.serial.flatMap { $0.isEmpty ? nil : $0 } ?? "usb-\(String(device.locationID, radix: 16))"
    }

    /// Busy when another app holds the interface; DroidDrive's own hold is not busy.
    static func state(of interface: UsbInterfaceInfo) -> PhoneState {
        guard let holder = interface.holder, !holder.isCurrentProcess, !holder.isDriver else { return .ready }
        return .busy(by: holder.processName)
    }

    static func deviceError(_ error: UsbError) -> DeviceError {
        switch error {
        case .exclusiveAccess(let holder): .busy(by: holder?.processName)
        default: .disconnected
        }
    }
}

/// MTP over USB (plan phase 2): phones in "File transfer" mode, with or without USB
/// debugging. The registry prefers ADB when both are there, unless the user chose MTP.
struct MtpSource: DeviceSource {
    let id = "usb-mtp"

    func scan() async throws -> [DiscoveredPhone] {
        UsbRegistry.devices().compactMap { device in
            guard let interface = device.mtpInterface else { return nil }
            return DiscoveredPhone(id: UsbAdbSource.phoneId(device), model: device.displayName, connection: .mtpUSB,
                                   state: UsbAdbSource.state(of: interface), address: String(device.registryID))
        }
    }

    func makeTransport(for phone: DiscoveredPhone) async throws -> any DeviceTransport {
        guard let registryID = UInt64(phone.address), let device = UsbRegistry.device(registryID: registryID) else {
            throw DeviceError.disconnected
        }
        return try await MtpTransport.open(device: device)
    }
}

/// Phones paired with DroidDrive over Wi-Fi (plan phase 3). `WifiReconnector` watches
/// mDNS (and retries Android ≤ 10 phones on a timer) and hands over ready connections;
/// this source shows them as phones and lends each connection to the registry once.
/// When the registry asks again, the connection it had failed, so it is dropped and the
/// reconnector is told to connect anew when the phone shows up (FR-15).
actor WifiSource: DeviceSource {
    nonisolated let id = "wifi"
    let store: PairedDeviceStore
    private var live: [String: (device: PairedDevice, transport: AdbTransport, lent: Bool)] = [:]
    private var reconnector: WifiReconnector?
    private var starting = false

    init(store: PairedDeviceStore) {
        self.store = store
    }

    func scan() async throws -> [DiscoveredPhone] {
        await startIfNeeded()
        return live.map { serial, entry in
            DiscoveredPhone(id: serial, model: entry.device.model ?? entry.transport.info.model, connection: .adbWiFi,
                            state: .ready, address: entry.device.id)
        }
    }

    func makeTransport(for phone: DiscoveredPhone) async throws -> any DeviceTransport {
        guard var entry = live[phone.id] else { throw DeviceError.disconnected }
        if entry.lent {
            live[phone.id] = nil
            await reconnector?.markDisconnected(id: entry.device.id)
            throw DeviceError.disconnected
        }
        entry.lent = true
        live[phone.id] = entry
        return entry.transport
    }

    /// A phone the Wi-Fi sheet just paired and connected.
    func adopt(_ device: PairedDevice, _ transport: AdbTransport) {
        let serial = transport.info.serial.isEmpty ? device.id : transport.info.serial
        live[serial] = (device, transport, false)
    }

    /// Forget a removed phone (FR-20): it must be paired again.
    func forget(serial: String) async {
        if let entry = live.removeValue(forKey: serial) {
            await reconnector?.markDisconnected(id: entry.device.id)
        }
        for device in (try? await store.all()) ?? [] where device.serial == serial || device.id == serial {
            try? await store.remove(id: device.id)
        }
    }

    private func startIfNeeded() async {
        guard reconnector == nil, !starting else { return }
        starting = true
        defer { starting = false }
        // Nothing paired yet: no key or mDNS browsing needed.
        guard let paired = try? await store.all(), !paired.isEmpty else { return }
        do {
            let reconnector = WifiReconnector(store: store, connector: try await AdbKeyProvider.shared.wifiConnector())
            self.reconnector = reconnector
            await reconnector.start()
            Task { [weak self] in
                for await event in reconnector.events {
                    switch event {
                    case .connected(let device, let transport):
                        await self?.adopt(device, transport)
                    case .failed(let device, let error):
                        log.error("Wi-Fi reconnect to \(device.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        } catch {
            log.error("Wi-Fi source unavailable: \(String(describing: error), privacy: .public)")
        }
    }
}
