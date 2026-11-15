import SwiftUI

/// One numbered step with an SF Symbol, used by the first-run guides.
struct GuideStep: View {
    let number: Int
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number). \(title)").font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shown when no phone is connected (spec §6: step-by-step guidance, not an error).
struct GettingStartedView: View {
    let adbMissing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Connect an Android phone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.title2.bold())
                Text("DroidDrive shows your phone's storage in Finder, like a USB drive. Do this once per phone:")
                    .foregroundStyle(.secondary)
                if adbMissing { AdbServerNote() }
                GuideStep(number: 1, symbol: "hammer",
                          title: "Turn on Developer options",
                          detail: "On the phone, open Settings → About phone and tap Build number seven times. "
                              + "Enter the phone's PIN if asked.")
                GuideStep(number: 2, symbol: "ladybug",
                          title: "Turn on USB debugging",
                          detail: "Open Settings → System → Developer options and switch on USB debugging.")
                GuideStep(number: 3, symbol: "cable.connector",
                          title: "Connect the cable and tap Allow",
                          detail: "Plug the phone into this Mac, unlock it, and tap Allow on \"Allow USB debugging?\". "
                              + "Tick \"Always allow from this computer\" so it does not ask again.")
                GuideStep(number: 4, symbol: "externaldrive.badge.checkmark",
                          title: "Find it in Finder",
                          detail: "Each storage (internal storage, SD card) appears under Locations in the Finder "
                              + "sidebar. The first time, macOS asks you to turn DroidDrive on in System Settings.")
                Divider()
                Label("Over Wi-Fi (Android 11 and later)", systemImage: "wifi").font(.headline)
                Text("Until DroidDrive's own pairing screen arrives, pair with adb: on the phone open Developer options → "
                     + "Wireless debugging → Pair device with pairing code, then run adb pair <ip>:<port> and "
                     + "adb connect <ip>:<port> in Terminal. The phone then appears here like a cabled one.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("File Transfer mode (MTP)", systemImage: "folder.badge.gearshape").font(.headline)
                Text("Phones without USB debugging use File Transfer mode: after plugging in, pull down the "
                     + "notifications, tap \"Charging this device via USB\" and choose File transfer. DroidDrive "
                     + "supports this mode in a later version; USB debugging works today.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

/// The adb server is optional: DroidDrive reaches phones over USB and paired Wi-Fi by
/// itself; adb only matters for phones paired with `adb pair`.
struct AdbServerNote: View {
    var body: some View {
        GroupBox {
            Label {
                Text("adb is not running. That is fine for phones connected by cable or paired in "
                     + "Connect via Wi-Fi. Only phones paired with adb pair need it: run adb start-server in Terminal.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "terminal").foregroundStyle(.orange)
            }
            .padding(4)
        }
    }
}

/// macOS starts new drives switched off (spike S0-c) until the user enables DroidDrive.
struct EnableExtensionCard: View {
    let openSettings: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Turn on DroidDrive in System Settings", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("macOS keeps new drives switched off until you allow them. Open System Settings → General → "
                     + "Login Items & Extensions, find File Providers (or DroidDrive under By App) and switch "
                     + "DroidDrive on. Until then, the drive in Finder stays empty.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings…", action: openSettings)
            }
            .padding(4)
        }
    }
}

/// The phone asked "Allow USB debugging?" and is waiting for the user.
struct ApprovalCard: View {
    var body: some View {
        GroupBox {
            Label {
                Text("Unlock the phone and tap Allow on \"Allow USB debugging?\". If no prompt shows, unplug the "
                     + "cable and plug it in again, or turn USB debugging off and on.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.tap").foregroundStyle(.tint)
            }
            .padding(4)
        }
    }
}
