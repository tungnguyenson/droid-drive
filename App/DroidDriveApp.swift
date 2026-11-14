import DeviceService
import SwiftUI

/// Menu bar app (spec §6). No Dock icon (`LSUIElement`); windows open from the menu.
@main
struct DroidDriveApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var manager: DeviceManager

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _manager = StateObject(wrappedValue: DeviceManager(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(manager: manager)
        } label: {
            // The label exists from launch; the menu body only when opened.
            Image(systemName: menuSymbol)
                .task { manager.start() }
        }
        .menuBarExtraStyle(.menu)

        Window("Devices", id: WindowID.devices) {
            DevicesWindow(manager: manager)
        }
        .defaultSize(width: 760, height: 520)

        Window("Transfer Log", id: WindowID.transferLog) {
            TransferLogWindow(manager: manager)
        }
        .defaultSize(width: 900, height: 480)

        Window("Connect via Wi-Fi", id: WindowID.wifi) {
            WifiWindow(manager: manager)
        }
        .windowResizability(.contentSize)

        Window("DroidDrive Settings", id: WindowID.settings) {
            SettingsWindow(manager: manager, settings: settings)
        }
        .windowResizability(.contentSize)
    }

    private var menuSymbol: String {
        if !manager.activeTransfers.isEmpty { return "arrow.up.arrow.down.circle" }
        return manager.devices.contains(where: \.isMounted) ? "iphone.circle.fill" : "iphone"
    }
}

enum WindowID {
    static let devices = "devices"
    static let transferLog = "transfer-log"
    static let settings = "settings"
    static let wifi = "wifi"
}

/// Opens a window and brings the (Dock-less) app to the front.
struct WindowOpener {
    let openWindow: OpenWindowAction

    func callAsFunction(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
