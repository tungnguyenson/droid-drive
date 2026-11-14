import DroidCore
import Foundation
import os

let mtpLog = Logger(subsystem: "com.droiddrive.mtp", category: "transport")

/// `DeviceTransport` over MTP (plan P2-07), with the same semantics as `AdbTransport`:
/// names go to the device as given (Mac names are NFC by construction of `RemotePath`),
/// names from the device keep their exact bytes, errors map to `DeviceError`, and
/// progress counts bytes.
///
/// MTP addresses objects by handle, not path. Storages are mapped to the same paths ADB
/// uses (`/storage/emulated/0` for internal storage, `/storage/XXXX-XXXX` for an SD card),
/// so a Finder domain is the same drive over MTP and ADB. Handles are looked up by
/// listing parents and cached for the session; events keep the cache current.
public actor MtpTransport: DeviceTransport {
    public static let listBatchSize = 500
    /// Spec §5.3: read in 1 MB chunks so progress moves and a cancel takes effect.
    public static let readChunk: UInt32 = 1 << 20
    /// SendPartialObject chunk when editing in place.
    static let editChunk: UInt64 = 16 << 20
    /// Writes larger than this check free space first (spec §5.6).
    public static let freeSpaceCheckThreshold: UInt64 = 100 << 20
    public static let internalRoot = RemotePath("/storage/emulated/0")

    public nonisolated let info: DeviceInfo
    public nonisolated let changes: AsyncStream<ChangeHint>
    public nonisolated let session: MtpSession
    let changesContinuation: AsyncStream<ChangeHint>.Continuation
    let timeZone: TimeZone
    var cache = MtpObjectCache()
    var storageRoots: [StorageRoot]?
    /// Cleared when the device rejects GetObjectPropList for folders.
    var usePropList: Bool
    private var eventTask: Task<Void, Never>?

    struct StorageRoot: Sendable {
        let id: UInt32
        let root: RemotePath
        let info: StorageInfo
    }

    /// Wraps an open session. `serial` overrides the DeviceInfo serial: the USB serial
    /// number equals `ro.serialno`, which keys the Finder drive, while Android's MTP
    /// serial may differ (spec §5.4 "one phone, one identity").
    public init(session: MtpSession, serial: String? = nil, timeZone: TimeZone = .current) {
        let device = session.deviceInfo
        self.session = session
        self.timeZone = timeZone
        self.usePropList = device.supports(.getObjectPropList)
        self.info = DeviceInfo(serial: serial.flatMap { $0.isEmpty ? nil : $0 } ?? device.serialNumber,
                               manufacturer: device.manufacturer, model: device.model, androidVersion: nil)
        (changes, changesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        Task { await self.startEvents() }
    }

    private func startEvents() {
        let events = session.events
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.finishChanges()
        }
    }

    private func finishChanges() { changesContinuation.finish() }

    /// Closes the MTP session and releases the USB interface.
    public func close() async {
        eventTask?.cancel()
        await session.close()
        changesContinuation.finish()
    }

    // MARK: Storages

    public func storages() async throws -> [StorageInfo] {
        try await mapped(.root) { try await self.loadStorages().map(\.info) }
    }

    func loadStorages() async throws -> [StorageRoot] {
        var found: [(UInt32, PtpStorageInfo)] = []
        for id in try await session.storageIDs() {
            do {
                found.append((id, try await session.storageInfo(id)))
            } catch let error as MtpResponseError where error.code == .storeNotAvailable || error.code == .invalidStorageID {
                continue // an SD card being unmounted
            }
        }
        let roots = Self.roots(for: found)
        storageRoots = roots
        return roots
    }

    /// Maps MTP storages to the paths ADB uses: the first fixed storage is internal
    /// storage, others are `/storage/<volume id>` when the label looks like one
    /// ("1234-ABCD"), else `/storage/<storage id in hex>`.
    static func roots(for storages: [(UInt32, PtpStorageInfo)]) -> [StorageRoot] {
        var internalTaken = false
        return storages.map { id, ptp in
            let hex = String(format: "%08X", id)
            if !ptp.isRemovable && !internalTaken {
                internalTaken = true
                return StorageRoot(id: id, root: internalRoot,
                                   info: StorageInfo(id: hex, kind: .internal, root: internalRoot,
                                                     capacity: ptp.maxCapacity, free: ptp.freeSpace))
            }
            let label = ptp.volumeLabel
            let isVolumeID = label.count == 9 && label.utf8.enumerated().allSatisfy { index, byte in
                index == 4 ? byte == UInt8(ascii: "-") : (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46)
            }
            let root = RemotePath("/storage").appending(exact: isVolumeID ? label : hex)
            return StorageRoot(id: id, root: root,
                               info: StorageInfo(id: hex, kind: .removable, root: root,
                                                 capacity: ptp.maxCapacity, free: ptp.freeSpace))
        }
    }

    func roots() async throws -> [StorageRoot] {
        if let storageRoots { return storageRoots }
        return try await loadStorages()
    }

    // MARK: Resolving paths

    /// What a path refers to.
    enum Location: Sendable {
        /// "/" or "/storage": an ancestor of storage roots, not a device object.
        case virtual(RemotePath)
        case storageRoot(StorageRoot)
        case object(MtpNode)

        var isDirectory: Bool {
            if case .object(let node) = self { return node.kind == .directory }
            return true
        }
    }

    func locate(_ path: RemotePath) async throws -> Location {
        let roots = try await roots()
        if let root = roots.filter({ path.isDescendant(of: $0.root) }).max(by: { $0.root.string.count < $1.root.string.count }) {
            if PathKey(path) == PathKey(root.root) { return .storageRoot(root) }
            do {
                return .object(try await resolveObject(path, in: root))
            } catch DeviceError.notFound {
                throw DeviceError.notFound(path) // like ADB: the path asked for, not the missing ancestor
            }
        }
        if roots.contains(where: { $0.root.isDescendant(of: path) }) { return .virtual(path) }
        throw DeviceError.notFound(path)
    }

    private func resolveObject(_ path: RemotePath, in root: StorageRoot) async throws -> MtpNode {
        if let node = cache.node(at: path) { return node }
        let parent: Location = PathKey(path.parent) == PathKey(root.root)
            ? .storageRoot(root) : .object(try await resolveObject(path.parent, in: root))
        guard parent.isDirectory else { throw DeviceError.notFound(path) }
        if !cache.isFreshlyListed(path.parent) {
            _ = try await listChildren(of: parent, at: path.parent, emit: { _ in })
        }
        guard let node = cache.node(at: path) else { throw DeviceError.notFound(path) }
        return node
    }

    /// The node at `path`, or nil when nothing is there (other errors still throw).
    func lookup(_ path: RemotePath) async throws -> Location? {
        do {
            return try await locate(path)
        } catch DeviceError.notFound {
            return nil
        }
    }

    /// Runs `body` on the object at `path`. If the device says the cached handle is no
    /// longer valid (deleted while events were missed), forgets it and tries once more.
    func withObject<T: Sendable>(_ path: RemotePath, _ body: (MtpNode) async throws -> T) async throws -> T {
        for attempt in 0..<2 {
            guard case .object(let node) = try await locate(path) else {
                throw DeviceError.permissionDenied(path)
            }
            do {
                return try await body(node)
            } catch let error as MtpResponseError where error.code == .invalidObjectHandle && attempt == 0 {
                cache.remove(path)
                cache.invalidateListing(path.parent)
            }
        }
        throw DeviceError.notFound(path)
    }

    // MARK: Listing

    public nonisolated func list(_ dir: RemotePath) -> AsyncThrowingStream<[RemoteEntry], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamList(dir) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamList(_ dir: RemotePath, emit: @escaping @Sendable ([RemoteEntry]) -> Void) async throws {
        try await mapped(dir) {
            let location = try await self.locate(dir)
            guard location.isDirectory else { throw DeviceError.unsupported("\(dir) is not a folder") }
            if case .virtual = location {
                let roots = try await self.roots()
                let names = Set(roots.compactMap { root -> String? in
                    guard root.root.isDescendant(of: dir), PathKey(root.root) != PathKey(dir) else { return nil }
                    let rest = root.root.replacingPrefix(dir, with: .root).string.dropFirst()
                    return rest.split(separator: "/").first.map(String.init)
                })
                let entries = names.sorted().map {
                    RemoteEntry(path: dir.appending(exact: $0), kind: .directory, size: 0, mtime: Date(timeIntervalSince1970: 0))
                }
                if !entries.isEmpty { emit(entries) }
                return
            }
            _ = try await self.listChildren(of: location, at: dir) { nodes in emit(nodes.map(\.entry)) }
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteEntry {
        try await mapped(path) {
            switch try await self.locate(path) {
            case .virtual, .storageRoot:
                return RemoteEntry(path: path, kind: .directory, size: 0, mtime: Date(timeIntervalSince1970: 0))
            case .object:
                // Fresh from the device: the version (size + mtime) decides conflicts.
                return try await self.withObject(path) { node in
                    try await self.refresh(node).entry
                }
            }
        }
    }

    /// Re-reads one object's metadata and updates the cache.
    func refresh(_ node: MtpNode) async throws -> MtpNode {
        let fresh = try await fetchNode(node.handle, parentPath: node.path.parent)
        cache.insert(fresh)
        return fresh
    }

    // MARK: Errors

    /// Runs `body`, mapping MTP and USB failures to `DeviceError` for `path`.
    func mapped<T: Sendable>(_ path: RemotePath, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as MtpResponseError {
            throw Self.deviceError(error, path: path)
        }
    }

    static func deviceError(_ error: MtpResponseError, path: RemotePath) -> DeviceError {
        switch error.code {
        case .invalidObjectHandle, .invalidParentObject, .invalidStorageID, .storeNotAvailable:
            return .notFound(path)
        case .storeFull:
            return .noSpace(needed: 0, available: 0)
        case .accessDenied, .objectWriteProtected, .storeReadOnly:
            return .permissionDenied(path)
        case .operationNotSupported, .specificationByFormatUnsupported, .objectPropNotSupported:
            return .unsupported("The phone does not support \(error.operation) over MTP")
        case .sessionNotOpen:
            return .disconnected
        case .objectTooLarge:
            return .unsupported("The phone's storage cannot hold files this large (FAT32 limit)")
        default:
            return .protocolError(error.description)
        }
    }
}
