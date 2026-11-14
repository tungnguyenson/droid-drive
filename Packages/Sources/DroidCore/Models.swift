import Foundation

/// The one error type every transport returns (spec §5.2). Layers above map it to
/// `NSFileProviderError` / UI text.
public enum DeviceError: Error, Equatable, Sendable {
    case disconnected
    case busy(by: String?)
    case notFound(RemotePath)
    case exists(RemotePath)
    case noSpace(needed: UInt64, available: UInt64)
    case permissionDenied(RemotePath)
    case unsupported(String)
    case invalidName(String, reason: String)
    case protocolError(String)
}

public enum EntryKind: String, Sendable, Codable {
    case file
    case directory
    case symlink
    case other
}

/// One file or directory on the device.
public struct RemoteEntry: Hashable, Sendable {
    public let path: RemotePath
    public let kind: EntryKind
    public let size: UInt64
    public let mtime: Date
    /// POSIX mode bits when the transport knows them (ADB), nil for MTP.
    public let mode: UInt32?
    /// Transport-private key (MTP object handle). Valid for one session only.
    public let transportKey: String?

    public init(path: RemotePath, kind: EntryKind, size: UInt64, mtime: Date,
                mode: UInt32? = nil, transportKey: String? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.mode = mode
        self.transportKey = transportKey
    }

    public var name: String { path.name }

    /// Version used for conflict detection (spec §5.5): size and mtime combined.
    /// Mtime is truncated to whole seconds because ADB `LIST`/`SEND` carry seconds only.
    public var version: String {
        "\(size)-\(Int64(mtime.timeIntervalSince1970.rounded(.down)))"
    }
}

public struct DeviceInfo: Hashable, Sendable {
    public let serial: String
    public let manufacturer: String
    public let model: String
    public let androidVersion: String?

    public init(serial: String, manufacturer: String, model: String, androidVersion: String?) {
        self.serial = serial
        self.manufacturer = manufacturer
        self.model = model
        self.androidVersion = androidVersion
    }
}

public struct StorageInfo: Hashable, Sendable {
    public enum Kind: String, Sendable { case `internal`, removable }

    /// Stable id: the mount path for ADB, the storage id for MTP.
    public let id: String
    public let kind: Kind
    public let root: RemotePath
    public let capacity: UInt64
    public let free: UInt64

    public init(id: String, kind: Kind, root: RemotePath, capacity: UInt64, free: UInt64) {
        self.id = id
        self.kind = kind
        self.root = root
        self.capacity = capacity
        self.free = free
    }

    /// Display name used for the Finder domain: "Pixel 8 · Internal storage" (FR-03).
    public func displayName(model: String) -> String {
        let label = kind == .internal ? "Internal storage" : "SD card \(id.split(separator: "/").last ?? "")"
        return "\(model) · \(label)"
    }
}

/// Hint that something under `path` changed on the device. ADB never emits these
/// (it relies on periodic refresh); MTP turns device events into them.
public enum ChangeHint: Hashable, Sendable {
    case changed(RemotePath)
    case storagesChanged
}
