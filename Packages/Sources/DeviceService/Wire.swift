import DroidCore
import Foundation

// JSON shapes carried over the XPC link between the File Provider extension and the
// app (spec §5.1). File contents never travel in these messages: they go through file
// descriptors (see `DeviceHostXPC`). Paths keep their exact bytes, because a name an
// Android app created in NFD must be addressed with those bytes again (spec §5.6).

struct WireEntry: Codable, Sendable, Equatable {
    var path: String
    var kind: EntryKind
    var size: UInt64
    var mtime: Double
    var mode: UInt32?
    var transportKey: String?

    init(_ entry: RemoteEntry) {
        path = entry.path.string
        kind = entry.kind
        size = entry.size
        mtime = entry.mtime.timeIntervalSince1970
        mode = entry.mode
        transportKey = entry.transportKey
    }

    var entry: RemoteEntry {
        RemoteEntry(path: RemotePath(exact: path), kind: kind, size: size,
                    mtime: Date(timeIntervalSince1970: mtime), mode: mode, transportKey: transportKey)
    }
}

struct WireInfo: Codable, Sendable, Equatable {
    var serial: String
    var manufacturer: String
    var model: String
    var androidVersion: String?

    init(_ info: DeviceInfo) {
        serial = info.serial
        manufacturer = info.manufacturer
        model = info.model
        androidVersion = info.androidVersion
    }

    var info: DeviceInfo {
        DeviceInfo(serial: serial, manufacturer: manufacturer, model: model, androidVersion: androidVersion)
    }
}

struct WireStorage: Codable, Sendable, Equatable {
    var id: String
    var removable: Bool
    var root: String
    var capacity: UInt64
    var free: UInt64

    init(_ storage: StorageInfo) {
        id = storage.id
        removable = storage.kind == .removable
        root = storage.root.string
        capacity = storage.capacity
        free = storage.free
    }

    var storage: StorageInfo {
        StorageInfo(id: id, kind: removable ? .removable : .internal, root: RemotePath(exact: root),
                    capacity: capacity, free: free)
    }
}

/// `DeviceError` as it crosses the process boundary. Errors that are not a
/// `DeviceError` become `protocolError` with their description.
enum WireError: Codable, Sendable, Equatable {
    case disconnected
    case busy(by: String?)
    case notFound(String)
    case exists(String)
    case noSpace(needed: UInt64, available: UInt64)
    case permissionDenied(String)
    case unsupported(String)
    case invalidName(String, reason: String)
    case protocolError(String)
    case cancelled

    init(_ error: Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        guard let device = error as? DeviceError else {
            self = .protocolError(String(describing: error))
            return
        }
        switch device {
        case .disconnected: self = .disconnected
        case .busy(let by): self = .busy(by: by)
        case .notFound(let path): self = .notFound(path.string)
        case .exists(let path): self = .exists(path.string)
        case .noSpace(let needed, let available): self = .noSpace(needed: needed, available: available)
        case .permissionDenied(let path): self = .permissionDenied(path.string)
        case .unsupported(let message): self = .unsupported(message)
        case .invalidName(let name, let reason): self = .invalidName(name, reason: reason)
        case .protocolError(let message): self = .protocolError(message)
        }
    }

    var error: Error {
        switch self {
        case .disconnected: DeviceError.disconnected
        case .busy(let by): DeviceError.busy(by: by)
        case .notFound(let path): DeviceError.notFound(RemotePath(exact: path))
        case .exists(let path): DeviceError.exists(RemotePath(exact: path))
        case .noSpace(let needed, let available): DeviceError.noSpace(needed: needed, available: available)
        case .permissionDenied(let path): DeviceError.permissionDenied(RemotePath(exact: path))
        case .unsupported(let message): DeviceError.unsupported(message)
        case .invalidName(let name, let reason): DeviceError.invalidName(name, reason: reason)
        case .protocolError(let message): DeviceError.protocolError(message)
        case .cancelled: CancellationError()
        }
    }
}

/// Requests without a file descriptor.
enum HostRequest: Codable, Sendable, Equatable {
    /// Confirms the app can reach the phone `serial` now and returns its identity.
    case hello(serial: String)
    case storages
    case stat(path: String)
    /// Starts a listing; the reply is a listing id for `listNext`.
    case listStart(path: String)
    case listNext(listing: String)
    case listCancel(listing: String)
    case mkdir(path: String)
    case delete(path: String, recursive: Bool)
    case rename(from: String, to: String)
    case cancelTransfer(id: String)
}

struct ReadRequest: Codable, Sendable, Equatable {
    var transferId: String
    var path: String
    var rangeStart: UInt64?
    var rangeEnd: UInt64?
}

struct WriteRequest: Codable, Sendable, Equatable {
    var transferId: String
    var path: String
    var mtime: Double?
}

enum HostReply: Codable, Sendable, Equatable {
    case ok
    case info(WireInfo)
    case storages([WireStorage])
    case entry(WireEntry)
    case listing(String)
    case batch([WireEntry], done: Bool)
    case failure(WireError)
}

enum WireCodec {
    static func encode<T: Encodable>(_ value: T) -> Data {
        // Encoding these plain structs cannot fail.
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DeviceError.protocolError("Malformed message between DroidDrive and its Finder extension")
        }
    }
}
