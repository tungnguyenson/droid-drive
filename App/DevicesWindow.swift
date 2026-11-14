import DeviceService
import SwiftUI

/// The Devices window (spec §6): phones in the sidebar, dimmed while absent; the
/// selected phone's details, storages and settings on the right.
struct DevicesWindow: View {
    @ObservedObject var manager: DeviceManager
    @State private var selection: String?

    private var adbMissing: Bool { manager.failedSources[AdbServerSource().id] != nil }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Devices") {
                    ForEach(manager.devices) { device in
                        Label {
                            VStack(alignment: .leading) {
                                Text(device.model)
                                Text(device.status).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: device.symbol)
                        }
                        .opacity(device.isConnected ? 1 : 0.5)
                        .tag(device.serial)
                    }
                }
                Section {
                    Label("Connect a Phone", systemImage: "questionmark.circle").tag(Self.guideTag)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let device = manager.devices.first(where: { $0.serial == selection }) {
                DeviceDetail(manager: manager, device: device)
            } else {
                GettingStartedView(adbMissing: adbMissing)
            }
        }
        .onAppear { selectFirstConnected() }
        .onChange(of: manager.devices.map(\.serial)) { _ in
            if selection == nil { selectFirstConnected() }
        }
    }

    private static let guideTag = "\u{1}guide"

    private func selectFirstConnected() {
        selection = manager.devices.first(where: \.isConnected)?.serial
    }
}

struct DeviceDetail: View {
    @ObservedObject var manager: DeviceManager
    let device: DeviceRow

    var body: some View {
        Form {
            Section {
                header
                if device.needsUserEnable {
                    EnableExtensionCard { manager.openExtensionSettings() }
                }
                if device.state == .unauthorized { ApprovalCard() }
                if case .conflict? = device.state {
                    Text("Another phone reports the same serial number (\(device.serial)), so DroidDrive mounts neither "
                         + "to avoid writing to the wrong one. Disconnect one of them.")
                        .foregroundStyle(.orange)
                }
            }
            Section("Storage") {
                if device.storages.isEmpty {
                    Text(device.isConnected ? "Reading storages…" : "Nothing mounted.").foregroundStyle(.secondary)
                }
                ForEach(device.storages) { storage in
                    StorageLine(storage: storage, device: device, manager: manager)
                }
            }
            Section("Settings") {
                Picker("Refresh", selection: Binding(
                    get: { device.refreshOverride },
                    set: { manager.setRefreshInterval($0, for: device.serial) })) {
                    Text("Default (\(manager.settings.defaultRefresh.label.lowercased()))").tag(RefreshInterval?.none)
                    ForEach(RefreshInterval.allCases) { Text($0.label).tag(RefreshInterval?.some($0)) }
                }
                Text("How often DroidDrive checks the phone for changes in the folders you have open in Finder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    if device.isReady {
                        if device.isMounted {
                            Button("Open in Finder") { Task { await manager.openInFinder(device) } }
                            Button("Unmount") { Task { await manager.unmount(device) } }
                        } else {
                            Button("Mount in Finder") { Task { await manager.mountByUser(device.serial) } }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    Spacer()
                    Button("Remove Device…", role: .destructive) { Task { await manager.removeDevice(device) } }
                }
                Text("Remove Device takes its drives out of Finder and deletes the files downloaded from it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = manager.lastError {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(device.model)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 40))
                .foregroundStyle(device.isConnected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.model).font(.title2.bold())
                Text(device.status).foregroundStyle(.secondary)
                Text(facts).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let version = device.androidVersion { parts.append("Android \(version)") }
        if !device.connections.isEmpty { parts.append(device.connections.map(\.label).joined(separator: ", ")) }
        if !device.isConnected, let seen = device.lastSeen {
            parts.append("Last connected \(seen.formatted(.relative(presentation: .named)))")
        }
        parts.append("Serial \(device.serial)")
        return parts.joined(separator: " · ")
    }
}

/// One storage with its capacity bar and actions.
struct StorageLine: View {
    let storage: StorageRow
    let device: DeviceRow
    @ObservedObject var manager: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: storage.label.hasPrefix("SD") ? "sdcard" : "internaldrive")
                Text(storage.label)
                Spacer()
                if storage.isMounted && storage.isPresent {
                    Button("Open") { Task { await manager.openInFinder(device, domainId: storage.domainId) } }
                        .buttonStyle(.link)
                } else if storage.isMounted && device.isReady {
                    Text("Not on the phone").foregroundStyle(.orange)
                    Button("Remove") { Task { await manager.removeStorage(storage) } }
                } else if !storage.isMounted {
                    Text("Not mounted").foregroundStyle(.secondary)
                }
            }
            if let capacity = storage.capacity, let free = storage.free, capacity > 0 {
                ProgressView(value: Double(capacity - min(free, capacity)), total: Double(capacity))
                Text("\(Format.bytes(free)) free of \(Format.bytes(capacity))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
