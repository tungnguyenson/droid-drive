import DroidCore
import Foundation

/// How often the app asks Finder to re-list the folders it has open (spec §5.5
/// "Refresh", §7). Per device, falling back to the app-wide default.
public enum RefreshInterval: Int, Codable, Sendable, CaseIterable, Identifiable {
    case off = 0
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300

    public static let `default` = RefreshInterval.thirtySeconds

    public var id: Int { rawValue }
    public var seconds: TimeInterval? { self == .off ? nil : TimeInterval(rawValue) }

    public var label: String {
        switch self {
        case .off: "Off"
        case .tenSeconds: "Every 10 seconds"
        case .thirtySeconds: "Every 30 seconds"
        case .oneMinute: "Every minute"
        case .fiveMinutes: "Every 5 minutes"
        }
    }
}

/// Decides which phones are due for a refresh signal.
public struct RefreshSchedule: Sendable, Equatable {
    private var lastSignal: [String: Date] = [:]

    public init() {}

    /// Phones whose interval has passed since their last signal. A phone never
    /// signalled is due at once.
    public func due(_ phones: [(id: String, interval: RefreshInterval)], now: Date) -> [String] {
        phones.compactMap { phone in
            guard let seconds = phone.interval.seconds else { return nil }
            guard let last = lastSignal[phone.id] else { return phone.id }
            return now.timeIntervalSince(last) >= seconds ? phone.id : nil
        }
    }

    public mutating func signalled(_ ids: [String], at now: Date) {
        ids.forEach { lastSignal[$0] = now }
    }

    public mutating func forget(_ id: String) {
        lastSignal[id] = nil
    }
}

/// Which domains a phone should have, given the storages it reports now (plan P1-13):
/// a storage that appeared after mounting (SD card inserted later, the emulator
/// mounting its SD card late) gets a domain; one that disappeared is reported as
/// missing. Missing domains are kept (like a pulled cable, spec FR-10): the user can
/// still open what was downloaded and remove the drive from the Devices window.
public enum StoragePlan {
    public struct Result: Equatable, Sendable {
        public let add: [StorageInfo]
        public let missing: [DomainIdentifier]
    }

    public static func plan(serial: String, storages: [StorageInfo], mounted: [DomainIdentifier]) -> Result {
        let mine = mounted.filter { $0.serial == serial }
        let wanted = storages.map { (DomainIdentifier(serial: serial, storage: $0), $0) }
        let wantedIds = Set(wanted.map(\.0))
        let mountedIds = Set(mine)
        return Result(add: wanted.filter { !mountedIds.contains($0.0) }.map(\.1),
                      missing: mine.filter { !wantedIds.contains($0) }.sorted { $0.rawValue < $1.rawValue })
    }
}

/// A phone that has been connected before (spec §6: the Devices window lists them,
/// dimmed while absent).
public struct KnownDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var model: String
    public var lastSeen: Date
    public var connection: ConnectionKind?
    public var androidVersion: String?
    public var refreshInterval: RefreshInterval?

    public init(id: String, model: String, lastSeen: Date, connection: ConnectionKind? = nil,
                androidVersion: String? = nil, refreshInterval: RefreshInterval? = nil) {
        self.id = id
        self.model = model
        self.lastSeen = lastSeen
        self.connection = connection
        self.androidVersion = androidVersion
        self.refreshInterval = refreshInterval
    }
}

public struct KnownDevices: Codable, Sendable, Equatable {
    public private(set) var devices: [KnownDevice]

    public init(devices: [KnownDevice] = []) {
        self.devices = devices
    }

    public init(data: Data?) {
        self.devices = data.flatMap { try? JSONDecoder().decode([KnownDevice].self, from: $0) } ?? []
    }

    public var data: Data { (try? JSONEncoder().encode(devices)) ?? Data() }

    public subscript(id: String) -> KnownDevice? { devices.first { $0.id == id } }

    /// Records a ready phone; keeps the user's per-device settings.
    public func seen(_ phone: DiscoveredPhone, androidVersion: String?, at now: Date) -> KnownDevices {
        var copy = self
        if let index = copy.devices.firstIndex(where: { $0.id == phone.id }) {
            copy.devices[index].model = phone.model
            copy.devices[index].lastSeen = now
            copy.devices[index].connection = phone.connection
            if let androidVersion { copy.devices[index].androidVersion = androidVersion }
        } else {
            copy.devices.append(KnownDevice(id: phone.id, model: phone.model, lastSeen: now,
                                            connection: phone.connection, androidVersion: androidVersion))
        }
        return copy
    }

    public func setting(_ interval: RefreshInterval?, for id: String) -> KnownDevices {
        var copy = self
        if let index = copy.devices.firstIndex(where: { $0.id == id }) {
            copy.devices[index].refreshInterval = interval
        }
        return copy
    }

    public func removing(_ id: String) -> KnownDevices {
        KnownDevices(devices: devices.filter { $0.id != id })
    }
}

/// Recognises the "Name (Mac copy).ext" / "Name (Mac copy 2).ext" files a conflict
/// leaves behind (`FileName.conflictName`), for the Finder badge (FR-18).
public enum ConflictCopy {
    public static func matches(_ name: String) -> Bool {
        let nfc = FileName.normalized(name)
        let stem: Substring
        if let dot = nfc.lastIndex(of: "."), dot != nfc.startIndex, nfc[..<dot].hasSuffix(")") {
            stem = nfc[..<dot]
        } else {
            stem = Substring(nfc)
        }
        guard stem.hasSuffix(")"), let open = stem.range(of: FileName.conflictSuffix.dropLast(), options: .backwards) else {
            return false
        }
        let tail = stem[open.upperBound...].dropLast()   // "" or " 2"
        return tail.isEmpty || (tail.first == " " && tail.dropFirst().allSatisfy(\.isNumber) && tail.count > 1)
    }
}
