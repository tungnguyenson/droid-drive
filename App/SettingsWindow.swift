import DeviceService
import SwiftUI

/// App-wide settings (spec §7). Per-device settings (refresh interval, Remove Device)
/// are in the Devices window.
struct SettingsWindow: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var settings: AppSettings
    @State private var freeing = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { settings.launchAtLogin },
                                                      set: { manager.setLaunchAtLogin($0) }))
                Toggle("Mount phones automatically when they connect", isOn: $settings.autoMount)
                Picker("When a phone offers both", selection: Binding(get: { settings.preferMTP },
                                                                    set: { manager.setPreferMTP($0) })) {
                    Text("Prefer ADB (faster)").tag(false)
                    Text("Prefer MTP (File Transfer)").tag(true)
                }
                Picker("Check for changes", selection: $settings.defaultRefresh) {
                    ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) }
                }
                Text("Applies to phones without their own setting in the Devices window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Notify when a large transfer finishes", isOn: $settings.notifyLargeTransfers)
                Stepper("Larger than \(settings.notifyThresholdMB) MB", value: $settings.notifyThresholdMB,
                        in: 50...10_000, step: 50)
                    .disabled(!settings.notifyLargeTransfers)
            }
            Section("Downloaded files") {
                Text("macOS keeps files you opened from the phone and removes them by itself when this Mac runs "
                     + "low on space. Free up space removes them now; they download again when opened.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(freeing ? "Freeing Up Space…" : "Free Up Space") {
                    freeing = true
                    Task {
                        await manager.freeUpSpace()
                        freeing = false
                    }
                }
                .disabled(freeing)
            }
            if let error = manager.lastError {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
