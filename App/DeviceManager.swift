import AdbPairing
import AppKit
import DeviceService
import DroidCore
import FileProvider
import os
import UserNotifications

private let log = Logger(subsystem: "com.droiddrive.app", category: "devices")

/// Owns the phones (spec §5.1): finds them through the device sources, mounts each
/// storage as a File Provider domain, lends the connections to the extension over XPC,
/// and nudges Finder to refresh (spec §5.5 "Refresh").
@MainActor
final class DeviceManager: ObservableObject {
    static let pollInterval: Duration = .seconds(2)
    /// How often a ready phone's storages are re-read, to mount an SD card that shows
    /// up later (plan P1-13). Each check is one shell call.
    static let storageCheckInterval: TimeInterval = 10
    /// Known-device bookkeeping is written at most this often per phone.
    static let lastSeenResolution: TimeInterval = 60

    let settings: AppSettings
    let monitor: TransferMonitor
    @Published private(set) var devices: [DeviceRow] = []
    @Published private(set) var failedSources: [String: String] = [:]
    @Published private(set) var activeTransfers: [ActiveTransfer] = []
    @Published private(set) var lastError: String?
    @Published private(set) var started = false

    private let registry: DeviceRegistry
    /// Phones paired with DroidDrive over Wi-Fi; shared with the "Connect via Wi-Fi" sheet.
    let wifiStore = PairedDeviceStore(fileURL: AppGroup.containerURL.appendingPathComponent("wifi-devices.json"))
    private let wifi: WifiSource
    private var linker: ExtensionLinker!
    private var details: [String: PhoneDetails] = [:]
    private var domains: [NSFileProviderDomain] = []
    private var schedule = RefreshSchedule()
    /// Phones the user unmounted or removed; auto-mount leaves them alone until replugged.
    private var userUnmounted: Set<String> = []
    private var mounting: Set<String> = []
    private var wasReady: Set<String> = []
    private var renamed: Set<String> = []
    private var tasks: [Task<Void, Never>] = []

    init(settings: AppSettings) {
        self.settings = settings
        monitor = TransferMonitor(log: TransferLog(url: AppGroup.transferLogURL))
        wifi = WifiSource(store: wifiStore)
        registry = DeviceRegistry(sources: [AdbServerSource(), UsbAdbSource(), MtpSource(), wifi],
                                  preferMTP: settings.preferMTP)
        linker = ExtensionLinker { [registry, monitor] id in
            DeviceHost(scope: HostScope(serial: id.serial, root: id.root), provider: registry, monitor: monitor)
        }
    }

    /// Model for the "Connect via Wi-Fi" window (spec §6). A phone it connects is handed
    /// to the Wi-Fi source right away, so it mounts without waiting for mDNS.
    func makeWifiModel() async throws -> WifiConnectModel {
        let model = WifiConnectModel(connector: try await AdbKeyProvider.shared.wifiConnector(), store: wifiStore)
        model.onConnected = { [weak self, wifi] device, transport in
            Task {
                await wifi.adopt(device, transport)
                await self?.poll()
            }
        }
        return model
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            try settings.applyFirstLaunchDefaults()
        } catch {
            report("Could not turn on Open at login", error)
        }
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        })
        tasks.append(Task { [weak self, monitor] in
            for await event in await monitor.events() {
                await self?.handle(event)
            }
        })
        tasks.append(Task { [monitor] in await monitor.log.prune() })
    }

    func setPreferMTP(_ value: Bool) {
        settings.preferMTP = value
        Task { await registry.setPreferMTP(value) }
    }

    // MARK: Polling

    private func poll() async {
        let snapshot = await registry.refresh()
        domains = ((try? await NSFileProviderManager.domains()) ?? [])
            .filter { DomainIdentifier(rawValue: $0.identifier.rawValue) != nil }
        linker.observe(domains)
        failedSources = snapshot.failedSources
        let ready = snapshot.phones.filter { $0.phone.state == .ready }
        await removeLegacyDomains(ready)
        for phone in ready where (details[phone.id].map { Date().timeIntervalSince($0.checked) } ?? .infinity)
            >= Self.storageCheckInterval {
            await checkStorages(phone)
        }
        rememberKnown(ready)
        rebuildRows(snapshot)

        let readyIds = Set(ready.map(\.id))
        // Reconnected (or the app just started): release edits queued while the phone or
        // the app was away now, not at the next refresh (FR-10).
        for serial in readyIds.subtracting(wasReady) { await signal(serial, resolveErrors: true) }
        for serial in wasReady.subtracting(readyIds) { schedule.forget(serial) }
        wasReady = readyIds
        // A phone that went away and came back counts as replugged.
        userUnmounted.formIntersection(readyIds)
        if settings.autoMount {
            for row in devices where row.isReady && !row.isMounted && !userUnmounted.contains(row.serial)
                && !mounting.contains(row.serial) {
                Task { await mount(row.serial) }
            }
        }
        let due = schedule.due(devices.filter { $0.isReady && $0.isMounted }
            .map { (id: $0.serial, interval: $0.refreshInterval) }, now: Date())
        for serial in due { await signal(serial, resolveErrors: false) }
        schedule.signalled(due, at: Date())
    }

    private func rebuildRows(_ snapshot: RegistrySnapshot? = nil) {
        let rows = DeviceRows.build(snapshot: snapshot ?? lastSnapshot, domains: domains, details: details,
                                    settings: settings, activeTransfers: activeTransfers)
        if let snapshot { lastSnapshot = snapshot }
        if rows != devices { devices = rows }
    }

    private var lastSnapshot = RegistrySnapshot(phones: [], failedSources: [:])

    /// Reads identity and storages; adds domains for storages that appeared since the
    /// phone was mounted (plan P1-13). Storages that went away keep their domain (shown
    /// as "Not on the phone" with a Remove button), like a pulled cable.
    private func checkStorages(_ phone: RegisteredPhone) async {
        do {
            let transport = try await registry.transport(for: phone.id)
            let storages = try await transport.storages()
            let before = details[phone.id].map { Set($0.storages.map(\.id)) }
            details[phone.id] = PhoneDetails(info: transport.info, storages: storages, checked: Date())
            // A storage that came back (SD card reinserted): retry edits queued for it.
            if let before, !Set(storages.map(\.id)).subtracting(before).isEmpty {
                await signal(phone.id, resolveErrors: true)
            }
            let mine = domains.compactMap { DomainIdentifier(rawValue: $0.identifier.rawValue) }
                .filter { $0.serial == phone.id }
            await updateDisplayNames(phone: phone, storages: storages)
            guard !mine.isEmpty, !userUnmounted.contains(phone.id) else { return }
            let plan = StoragePlan.plan(serial: phone.id, storages: storages, mounted: mine)
            for storage in plan.add {
                log.notice("mounting storage that appeared later: \(storage.id, privacy: .public)")
                try await addDomain(serial: phone.id, model: phone.phone.model, storage: storage)
            }
            if !plan.missing.isEmpty {
                log.notice("storages no longer on the phone: \(plan.missing.map(\.rawValue), privacy: .public)")
            }
        } catch {
            details[phone.id]?.checked = Date()
            if case DeviceError.disconnected = error { await registry.invalidate(phoneId: phone.id) }
            log.error("storage check failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Drives named by older builds (Vietnamese storage labels) get the current English name.
    private func updateDisplayNames(phone: RegisteredPhone, storages: [StorageInfo]) async {
        for storage in storages {
            let raw = DomainIdentifier(serial: phone.id, storage: storage).rawValue
            let wanted = storage.displayName(model: phone.phone.model)
            guard let domain = domains.first(where: { $0.identifier.rawValue == raw }), domain.displayName != wanted,
                  renamed.insert(raw).inserted else { continue }
            do {
                try await NSFileProviderManager.add(NSFileProviderDomain(identifier: domain.identifier, displayName: wanted))
            } catch {
                log.error("cannot rename drive: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func rememberKnown(_ ready: [RegisteredPhone]) {
        var known = settings.known
        let now = Date()
        for phone in ready {
            let version = details[phone.id]?.info.androidVersion
            let previous = known[phone.id]
            let stale = previous.map { now.timeIntervalSince($0.lastSeen) >= Self.lastSeenResolution } ?? true
            if stale || previous?.model != phone.phone.model || previous?.connection != phone.phone.connection
                || (version != nil && previous?.androidVersion != version) {
                known = known.seen(phone.phone, androidVersion: version, at: now)
            }
        }
        settings.update(known)
    }

    /// Builds before 14/11/2026 keyed drives by the adb serial ("emulator-5554"). Such
    /// a drive of a connected phone is replaced by one keyed by the phone's serial.
    private func removeLegacyDomains(_ ready: [RegisteredPhone]) async {
        for phone in ready {
            for domain in domains {
                guard let id = DomainIdentifier(rawValue: domain.identifier.rawValue), id.serial != phone.id,
                      id.serial == phone.phone.address else { continue }
                log.notice("replacing legacy drive \(domain.identifier.rawValue, privacy: .public)")
                try? await removeDomains([domain.identifier.rawValue], mode: .preserveDownloadedUserData)
            }
        }
    }

    /// Tells macOS to re-list the folders Finder has open; after a reconnect also clears
    /// a pending `serverUnreachable` so queued edits upload (FR-10).
    private func signal(_ serial: String, resolveErrors: Bool) async {
        log.info("signal \(serial, privacy: .public) resolveErrors=\(resolveErrors, privacy: .public)")
        for domain in domains where DomainIdentifier(rawValue: domain.identifier.rawValue)?.serial == serial {
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            if resolveErrors { try? await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable)) }
            try? await manager.signalEnumerator(for: .workingSet)
        }
    }

    // MARK: Transfers

    private func handle(_ event: TransferEvent) async {
        activeTransfers = await monitor.activeTransfers
        rebuildRows()
        guard case .finished(let record) = event, record.result == .succeeded, settings.notifyLargeTransfers,
              record.bytes >= UInt64(settings.notifyThresholdMB) << 20 else { return }
        await notify(record)
    }

    /// Spec §7: a notification when a transfer larger than the threshold finishes.
    private func notify(_ record: TransferRecord) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = record.direction == .download ? "Copied from \(record.deviceName)" : "Copied to \(record.deviceName)"
        content.body = "\(record.fileName) · \(Format.bytes(record.bytes))"
        try? await center.add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
    }

    // MARK: Actions

    func mount(_ serial: String) async {
        guard mounting.insert(serial).inserted else { return }
        defer { mounting.remove(serial) }
        do {
            let transport = try await registry.transport(for: serial)
            let storages = try await transport.storages()
            details[serial] = PhoneDetails(info: transport.info, storages: storages, checked: Date())
            let model = lastSnapshot.phones.first { $0.id == serial }?.phone.model ?? transport.info.model
            for storage in storages {
                try await addDomain(serial: serial, model: model, storage: storage)
            }
            lastError = nil
            await poll()
        } catch {
            // Do not retry every poll; a replug or the Mount button tries again.
            userUnmounted.insert(serial)
            report("Could not mount the phone", error)
        }
    }

    func mountByUser(_ serial: String) async {
        userUnmounted.remove(serial)
        await mount(serial)
    }

    private func addDomain(serial: String, model: String, storage: StorageInfo) async throws {
        let id = DomainIdentifier(serial: serial, storage: storage)
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id.rawValue),
                                          displayName: storage.displayName(model: model))
        try await NSFileProviderManager.add(domain)
    }

    /// FR-19: unmount; asks first when transfers are running. Edits not yet sent to the
    /// phone stay on the Mac (spec §5.5 "Unmount"). `.preserveDirtyUserData`, not
    /// `.preserveDownloadedUserData`: the latter leaves a copy of every downloaded file
    /// in a "<drive> (date)" folder, which a sandboxed app is not allowed to delete.
    func unmount(_ row: DeviceRow) async {
        guard await confirmCancellingTransfers(row, action: "Unmount") else { return }
        userUnmounted.insert(row.serial)
        do {
            try await removeDomains(Set(row.mountedDomains), mode: .preserveDirtyUserData)
            lastError = nil
            await poll()
        } catch {
            report("Could not unmount \(row.model)", error)
        }
    }

    /// Removes the drive of a storage the phone no longer has (SD card taken out).
    func removeStorage(_ storage: StorageRow) async {
        do {
            try await removeDomains([storage.domainId], mode: .preserveDirtyUserData)
            await poll()
        } catch {
            report("Could not remove \(storage.label)", error)
        }
    }

    /// FR-20 "Remove device": drives, their caches, and the phone's settings. Edits not
    /// yet sent to the phone stay on the Mac in a folder next to the drive.
    func removeDevice(_ row: DeviceRow) async {
        let alert = NSAlert()
        alert.messageText = "Remove \(row.model)?"
        alert.informativeText = "Its drives disappear from Finder and the files downloaded from it are deleted from "
            + "this Mac. Changes that were not copied to the phone yet are kept in a folder next to the drive."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await monitor.cancelAll(phoneId: row.serial)
        userUnmounted.insert(row.serial)
        do {
            try await removeDomains(Set(row.storages.filter(\.isMounted).map(\.domainId)), mode: .preserveDirtyUserData)
            settings.update(settings.known.removing(row.serial))
            details[row.serial] = nil
            schedule.forget(row.serial)
            // A removed phone must be paired again over Wi-Fi.
            await wifi.forget(serial: row.serial)
            lastError = nil
            await poll()
        } catch {
            report("Could not remove \(row.model)", error)
        }
    }

    func setRefreshInterval(_ interval: RefreshInterval?, for serial: String) {
        settings.setRefreshInterval(interval, for: serial)
        schedule.forget(serial)
        rebuildRows()
    }

    func openInFinder(_ row: DeviceRow, domainId: String? = nil) async {
        let wanted = domainId.map { [$0] } ?? row.mountedDomains
        do {
            for id in wanted {
                guard let domain = domains.first(where: { $0.identifier.rawValue == id }),
                      let manager = NSFileProviderManager(for: domain) else { continue }
                let url = try await manager.getUserVisibleURL(for: .rootContainer)
                await Self.revealInFinder(url)
                return
            }
        } catch {
            report("Could not open Finder", error)
        }
    }

    /// The URL File Provider hands a sandboxed app is security-scoped: opening it without
    /// claiming access makes Finder say "DroidDrive does not have permission to open …".
    /// Access is held until Finder has taken the URL, and opened with Finder explicitly.
    private static func revealInFinder(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: configuration)
        } catch {
            log.error("Finder open failed (\(String(describing: error), privacy: .public)); selecting instead")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Spec §7 "Free up space": evicts downloaded files of every drive; Finder downloads
    /// them again when opened. Files with changes not yet uploaded stay.
    func freeUpSpace() async {
        var failures = 0
        for domain in domains {
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            do {
                try await manager.evictItem(identifier: .rootContainer)
            } catch {
                failures += 1
                log.error("evict failed: \(String(describing: error), privacy: .public)")
            }
        }
        lastError = failures == 0 ? nil : "Some downloaded files could not be removed (\(failures) drive(s))."
    }

    /// System Settings → General → Login Items & Extensions, where File Providers are enabled.
    func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try settings.setLaunchAtLogin(enabled)
        } catch {
            report("Could not change Open at login", error)
        }
    }

    // MARK: Helpers

    private func confirmCancellingTransfers(_ row: DeviceRow, action: String) async -> Bool {
        let running = await monitor.activeCount(phoneId: row.serial)
        guard running > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "\(running) transfer\(running == 1 ? " is" : "s are") still running on \(row.model)"
        alert.informativeText = "\(action) cancels \(running == 1 ? "it" : "them"). Files that were not copied "
            + "to the phone yet stay on this Mac and are sent when the phone is mounted again."
        alert.addButton(withTitle: "\(action) Anyway")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        await monitor.cancelAll(phoneId: row.serial)
        return true
    }

    private func removeDomains(_ ids: Set<String>, mode: NSFileProviderManager.DomainRemovalMode) async throws {
        for domain in try await NSFileProviderManager.domains() where ids.contains(domain.identifier.rawValue) {
            let preserved = try await NSFileProviderManager.remove(domain, mode: mode)
            // A drive added again later starts from an empty cache, as macOS starts it empty.
            AppGroup.removeItemStore(domainIdentifier: domain.identifier.rawValue)
            if let preserved { Self.deleteIfOnlyFinderMetadata(preserved) }
        }
    }

    /// macOS keeps a "<drive> (date)" folder when a drive is removed. One that holds only
    /// Finder's .DS_Store files is noise; anything else is the user's and stays.
    private static func deleteIfOnlyFinderMetadata(_ folder: URL) {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
        guard files.allSatisfy({ $0.lastPathComponent == ".DS_Store" }) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            log.notice("kept preserved folder: \(String(describing: error), privacy: .public)")
        }
    }

    private func report(_ message: String, _ error: Error) {
        log.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        let reason = (error as? DeviceError)?.userMessage ?? error.localizedDescription
        lastError = "\(message): \(reason)"
    }
}

enum Format {
    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "–" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.2f s", seconds) : (seconds < 60 ? String(format: "%.1f s", seconds)
            : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s")
    }
}
