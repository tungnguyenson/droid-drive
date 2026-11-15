import DeviceService
import SwiftUI

/// The menu bar menu (spec §6).
struct MenuContent: View {
    @ObservedObject var manager: DeviceManager
    @Environment(\.openWindow) private var openWindow

    private var open: WindowOpener { WindowOpener(openWindow: openWindow) }
    private var connected: [DeviceRow] { manager.devices.filter(\.isConnected) }
    private var absentWithDrives: [DeviceRow] { manager.devices.filter { !$0.isConnected && $0.isMounted } }

    var body: some View {
        if connected.isEmpty {
            Text("No phone connected")
            Text("On the phone, turn on Wireless debugging, or plug in a cable")
            Button("How to Connect a Phone…") { open(WindowID.devices) }
        }
        ForEach(connected) { device in
            Section(title(device)) { actions(device) }
        }
        if !absentWithDrives.isEmpty {
            Section("Not connected") {
                ForEach(absentWithDrives) { device in
                    Button("Remove \(device.model)…") { Task { await manager.removeDevice(device) } }
                }
            }
        }
        if !manager.activeTransfers.isEmpty {
            Divider()
            Text("Transferring \(manager.activeTransfers.count) file\(manager.activeTransfers.count == 1 ? "" : "s")…")
        }
        if let error = manager.lastError {
            Divider()
            Text(error)
        }
        Divider()
        Button("Connect via Wi-Fi…") { open(WindowID.wifi) }
        Button("Devices…") { open(WindowID.devices) }
            .keyboardShortcut("d")
        Button("Transfer Log") { open(WindowID.transferLog) }
            .keyboardShortcut("l")
        Button("Settings…") { open(WindowID.settings) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit DroidDrive") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func actions(_ device: DeviceRow) -> some View {
        switch device.state {
        case .ready? where device.needsUserEnable:
            Text("macOS has DroidDrive turned off. Turn it on under File Providers.")
            Button("Open System Settings…") { manager.openExtensionSettings() }
            Button("Unmount") { Task { await manager.unmount(device) } }
        case .ready? where device.isMounted:
            Button("Open in Finder") { Task { await manager.openInFinder(device) } }
            Button("Unmount") { Task { await manager.unmount(device) } }
            ForEach(device.missingStorages) { storage in
                Button("Remove \(storage.label) (not on the phone)") { Task { await manager.removeStorage(storage) } }
            }
        case .ready?:
            Button("Mount in Finder") { Task { await manager.mountByUser(device.serial) } }
        case .unauthorized?:
            Text("Unlock the phone and tap Allow")
        case .conflict?:
            Text("Two phones report the same serial number, so neither is mounted.")
            Text("Disconnect one of them to mount the other.")
        case .busy(let by)?:
            Text("In use by \(by ?? "another app"). Quit that app, then try again.")
        case .offline?, nil:
            Text("Offline")
        }
    }

    private func title(_ device: DeviceRow) -> String {
        let link = device.connection.map { " (\($0.label))" } ?? ""
        return "\(device.model)\(link) · \(device.status)"
    }
}
