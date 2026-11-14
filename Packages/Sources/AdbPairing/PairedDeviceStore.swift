import DroidCore
import Foundation

/// A phone DroidDrive can reach over Wi-Fi without asking the user again (plan P3-08,
/// FR-15, FR-20).
public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Android 11+ wireless debugging: found again through `_adb-tls-connect._tcp`.
        case paired
        /// Android 10 and earlier after `tcpip`: reconnect to the last address on 5555.
        case tcpip
    }

    /// For `.paired`, the device GUID the phone returned when pairing, which is also its
    /// `_adb-tls-connect._tcp` service name (e.g. `adb-R5CT20ABCDE-xYz12A`). For
    /// `.tcpip`, the adb serial it was switched from.
    public let id: String
    /// `ro.serialno` once a connection has read it; the Finder drive is keyed by it.
    public var serial: String?
    public var kind: Kind
    public var model: String?
    public var lastHost: String?
    public var lastPort: UInt16?
    public var pairedAt: Date
    /// Which ADB key the phone trusts: the `AdbKeyStore` service/account (our TLS
    /// certificate is derived from that key, so it needs no storage of its own).
    public var keyReference: String

    public init(id: String, serial: String? = nil, kind: Kind, model: String? = nil,
                lastHost: String? = nil, lastPort: UInt16? = nil, pairedAt: Date = Date(),
                keyReference: String = PairedDevice.defaultKeyReference) {
        self.id = id
        self.serial = serial
        self.kind = kind
        self.model = model
        self.lastHost = lastHost
        self.lastPort = lastPort
        self.pairedAt = pairedAt
        self.keyReference = keyReference
    }

    public static let defaultKeyReference = "com.droiddrive.adbkey/default"
}

/// Paired phones, persisted as a small JSON file (no secrets in it: the ADB key lives
/// in the Keychain via `AdbKeyStore`). The app should pass a URL in its app group
/// container so the File Provider extension can read it too.
public actor PairedDeviceStore {
    public let fileURL: URL
    private var devices: [String: PairedDevice]?

    public init(fileURL: URL = PairedDeviceStore.defaultURL) { self.fileURL = fileURL }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DroidDrive/wifi-devices.json")
    }

    public func all() throws -> [PairedDevice] {
        try load().values.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func device(id: String) throws -> PairedDevice? { try load()[id] }

    /// Adds or replaces the device with the same id.
    public func upsert(_ device: PairedDevice) throws {
        var all = try load()
        all[device.id] = device
        try save(all)
    }

    /// Records where a known device was last reached (and its serial, once read).
    public func noteConnected(id: String, host: String, port: UInt16, serial: String?, model: String?) throws {
        var all = try load()
        guard var device = all[id] else { return }
        device.lastHost = host
        device.lastPort = port
        if let serial, !serial.isEmpty { device.serial = serial }
        if let model, !model.isEmpty { device.model = model }
        all[id] = device
        try save(all)
    }

    /// FR-20: forget a phone. It stays trusted on the phone's side until the user
    /// removes it under Wireless debugging → Paired devices.
    public func remove(id: String) throws {
        var all = try load()
        all.removeValue(forKey: id)
        try save(all)
    }

    private func load() throws -> [String: PairedDevice] {
        if let devices { return devices }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            devices = [:]
            return [:]
        }
        do {
            let list = try JSONDecoder.store.decode([PairedDevice].self, from: Data(contentsOf: fileURL))
            let loaded = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            devices = loaded
            return loaded
        } catch {
            throw DeviceError.protocolError("Could not read \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func save(_ all: [String: PairedDevice]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.store.encode(all.values.sorted { $0.id < $1.id })
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        devices = all
    }
}

private extension JSONEncoder {
    static var store: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var store: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
