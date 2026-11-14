import DeviceService
import DroidCore
import FileProvider
import Foundation

/// One storage of a phone in the Devices window: mounted, available, or gone.
struct StorageRow: Identifiable, Equatable {
    let domainId: String
    let label: String
    let capacity: UInt64?
    let free: UInt64?
    let isMounted: Bool
    /// The phone reports this storage now (false: SD card taken out, phone away).
    let isPresent: Bool
    /// macOS keeps this drive switched off until the user enables DroidDrive.
    let needsUserEnable: Bool

    var id: String { domainId }
}

/// One phone as the menu and the Devices window show it: connected now, or known from
/// before (spec §6: listed dimmed while absent).
struct DeviceRow: Identifiable, Equatable {
    let serial: String
    let model: String
    /// nil while the phone is not connected.
    let state: PhoneState?
    let connection: ConnectionKind?
    let connections: [ConnectionKind]
    let androidVersion: String?
    let lastSeen: Date?
    let storages: [StorageRow]
    let activeTransfers: Int
    let refreshInterval: RefreshInterval
    /// The per-device setting; nil follows the app-wide default.
    let refreshOverride: RefreshInterval?

    var id: String { serial }
    var isConnected: Bool { state != nil }
    var isReady: Bool { state == .ready }
    var mountedDomains: [String] { storages.filter(\.isMounted).map(\.domainId) }
    var isMounted: Bool { !mountedDomains.isEmpty }
    var needsUserEnable: Bool { storages.contains(where: \.needsUserEnable) }
    var missingStorages: [StorageRow] { storages.filter { $0.isMounted && !$0.isPresent && isReady } }

    var status: String {
        switch state {
        case nil: "Not connected"
        case .ready?:
            if needsUserEnable { "Turned off in System Settings" }
            else if activeTransfers > 0 { "Transferring \(activeTransfers) file\(activeTransfers == 1 ? "" : "s")" }
            else { isMounted ? "Mounted" : "Ready" }
        case .unauthorized?: "Waiting for approval on the phone"
        case .offline?: "Offline"
        case .conflict?: "Duplicate serial number"
        case .busy(let by)?: "In use by \(by ?? "another app")"
        }
    }

    var symbol: String {
        switch state {
        case nil: "iphone.slash"
        case .ready?: needsUserEnable ? "exclamationmark.triangle" : (isMounted ? "checkmark.circle.fill" : "iphone")
        case .unauthorized?: "hand.raised"
        case .offline?: "iphone.slash"
        case .conflict?, .busy?: "exclamationmark.triangle"
        }
    }
}

/// What the phone reported last time the app asked.
struct PhoneDetails: Equatable {
    var info: DeviceInfo
    var storages: [StorageInfo]
    var checked: Date
}

@MainActor
enum DeviceRows {
    /// "Pixel 8 · Internal storage" → "Internal storage".
    static func storageLabel(_ displayName: String) -> String {
        displayName.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
    }

    static func modelFromDomain(_ displayName: String) -> String {
        displayName.components(separatedBy: " · ").first ?? displayName
    }

    /// Present phones first (in the registry's order), then absent known phones and
    /// phones that only have drives left, most recently seen first.
    static func build(snapshot: RegistrySnapshot, domains: [NSFileProviderDomain], details: [String: PhoneDetails],
                      settings: AppSettings, activeTransfers: [ActiveTransfer]) -> [DeviceRow] {
        var domainsBySerial: [String: [NSFileProviderDomain]] = [:]
        for domain in domains {
            guard let id = DomainIdentifier(rawValue: domain.identifier.rawValue) else { continue }
            domainsBySerial[id.serial, default: []].append(domain)
        }
        var rows: [DeviceRow] = []
        var seen: Set<String> = []
        for registered in snapshot.phones {
            seen.insert(registered.id)
            rows.append(row(serial: registered.id, model: registered.phone.model, registered: registered,
                            domains: domainsBySerial[registered.id] ?? [], details: details[registered.id],
                            settings: settings, activeTransfers: activeTransfers))
        }
        var absent: [DeviceRow] = []
        let absentSerials = Set(settings.known.devices.map(\.id)).union(domainsBySerial.keys).subtracting(seen)
        for serial in absentSerials {
            let known = settings.known[serial]
            let mine = domainsBySerial[serial] ?? []
            let model = known?.model ?? mine.first.map { modelFromDomain($0.displayName) } ?? serial
            absent.append(row(serial: serial, model: model, registered: nil, domains: mine, details: details[serial],
                              settings: settings, activeTransfers: activeTransfers))
        }
        absent.sort { ($0.lastSeen ?? .distantPast, $0.model) > ($1.lastSeen ?? .distantPast, $1.model) }
        return rows + absent
    }

    private static func row(serial: String, model: String, registered: RegisteredPhone?,
                            domains: [NSFileProviderDomain], details: PhoneDetails?, settings: AppSettings,
                            activeTransfers: [ActiveTransfer]) -> DeviceRow {
        let known = settings.known[serial]
        let ready = registered?.phone.state == .ready
        var storages: [StorageRow] = []
        var listed: Set<String> = []
        let live = ready ? (details?.storages ?? []) : []
        for domain in domains.sorted(by: { $0.displayName < $1.displayName }) {
            let raw = domain.identifier.rawValue
            listed.insert(raw)
            let match = live.first { DomainIdentifier(serial: serial, storage: $0).rawValue == raw }
            storages.append(StorageRow(domainId: raw, label: match.map { storageLabel($0.displayName(model: model)) }
                                           ?? storageLabel(domain.displayName),
                                       capacity: match?.capacity, free: match?.free, isMounted: true,
                                       isPresent: match != nil, needsUserEnable: !domain.userEnabled))
        }
        for storage in live {
            let raw = DomainIdentifier(serial: serial, storage: storage).rawValue
            guard !listed.contains(raw) else { continue }
            storages.append(StorageRow(domainId: raw, label: storageLabel(storage.displayName(model: model)),
                                       capacity: storage.capacity, free: storage.free, isMounted: false,
                                       isPresent: true, needsUserEnable: false))
        }
        return DeviceRow(serial: serial, model: model, state: registered?.phone.state,
                         connection: registered?.phone.connection, connections: registered?.connections ?? [],
                         androidVersion: details?.info.androidVersion ?? known?.androidVersion,
                         lastSeen: known?.lastSeen,
                         storages: storages,
                         activeTransfers: activeTransfers.filter { $0.phoneId == serial }.count,
                         refreshInterval: settings.refreshInterval(for: serial),
                         refreshOverride: known?.refreshInterval)
    }
}
