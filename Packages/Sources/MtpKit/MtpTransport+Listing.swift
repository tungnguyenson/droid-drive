import DroidCore
import Foundation

/// Listing (plan P2-03): one GetObjectPropList per folder, decoded while it streams and
/// handed out in batches of 500; GetObjectHandles + GetObjectInfo per object when the
/// phone lacks GetObjectPropList or refuses it for folders.
extension MtpTransport {
    /// Lists `location`'s children, refreshes the cache with the complete result, and
    /// passes batches to `emit` as they are decoded.
    func listChildren(of location: Location, at dir: RemotePath,
                      emit: @escaping @Sendable ([MtpNode]) -> Void) async throws -> [MtpNode] {
        let storageID: UInt32
        let handle: UInt32?
        switch location {
        case .virtual: return []
        case .storageRoot(let root):
            storageID = root.id
            handle = nil
        case .object(let node):
            guard node.kind == .directory else { throw DeviceError.unsupported("\(dir) is not a folder") }
            storageID = node.storageID
            handle = node.handle
        }
        var nodes: [MtpNode]?
        if usePropList {
            nodes = try await listWithPropList(storageID: storageID, handle: handle, dir: dir, emit: emit)
        }
        if nodes == nil {
            nodes = try await listWithObjectInfo(storageID: storageID, handle: handle, dir: dir, emit: emit)
        }
        cache.setChildren(of: dir, nodes!)
        return nodes!
    }

    /// nil when the device refused before sending anything, so the caller falls back.
    private func listWithPropList(storageID: UInt32, handle: UInt32?, dir: RemotePath,
                                  emit: @escaping @Sendable ([MtpNode]) -> Void) async throws -> [MtpNode]? {
        // Android answers depth 1 on handle 0 with the root objects of *every* storage,
        // so the storage root is filtered by its own handle list.
        let allowed: Set<UInt32>? = handle == nil
            ? Set(try await session.objectHandles(storageID: storageID, parent: PtpHandle.root)) : nil
        let accumulator = PropListAccumulator(parentPath: dir, parentHandle: handle ?? PtpHandle.noParent,
                                              allowed: allowed, timeZone: timeZone,
                                              batchSize: Self.listBatchSize, emit: emit)
        do {
            try await session.objectPropList(handle ?? PtpHandle.noParent, depth: 1, onElements: accumulator.consume)
        } catch let error as MtpResponseError where accumulator.emittedCount == 0 && Self.refusesPropList(error.code) {
            mtpLog.notice("GetObjectPropList refused (\(error.code, privacy: .public)); using GetObjectInfo per object")
            usePropList = false
            return nil
        }
        return accumulator.finish()
    }

    static func refusesPropList(_ code: PtpResponseCode) -> Bool {
        [.operationNotSupported, .specificationByDepthUnsupported, .specificationByGroupUnsupported,
         .parameterNotSupported, .invalidObjectPropCode, .objectPropNotSupported, .invalidParameter].contains(code)
    }

    private func listWithObjectInfo(storageID: UInt32, handle: UInt32?, dir: RemotePath,
                                    emit: @escaping @Sendable ([MtpNode]) -> Void) async throws -> [MtpNode] {
        let handles = try await session.objectHandles(storageID: storageID, parent: handle ?? PtpHandle.root)
        var all: [MtpNode] = []
        var batch: [MtpNode] = []
        for child in handles {
            try Task.checkCancellation()
            let node: MtpNode
            do {
                node = try await fetchNodeWithObjectInfo(child, parentPath: dir)
            } catch let error as MtpResponseError where error.code == .invalidObjectHandle {
                continue // deleted while we were listing
            } catch DeviceError.protocolError(let message) where message.contains("not addressable") {
                continue
            }
            all.append(node)
            batch.append(node)
            if batch.count == Self.listBatchSize {
                emit(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { emit(batch) }
        return all
    }

    /// One object's metadata, by whichever operation the device supports.
    func fetchNode(_ handle: UInt32, parentPath: RemotePath) async throws -> MtpNode {
        if usePropList || session.supports(.getObjectPropList) {
            let accumulator = PropListAccumulator(parentPath: parentPath, parentHandle: nil, allowed: [handle],
                                                  timeZone: timeZone, batchSize: 1, emit: { _ in })
            do {
                try await session.objectPropList(handle, depth: 0, onElements: accumulator.consume)
                if let node = accumulator.finish().first { return node }
            } catch let error as MtpResponseError where Self.refusesPropList(error.code) {
                // fall through to ObjectInfo
            }
        }
        return try await fetchNodeWithObjectInfo(handle, parentPath: parentPath)
    }

    private func fetchNodeWithObjectInfo(_ handle: UInt32, parentPath: RemotePath) async throws -> MtpNode {
        let info = try await session.objectInfo(handle)
        var size = UInt64(info.compressedSize)
        if info.compressedSize == 0xFFFF_FFFF, session.supports(.getObjectPropValue) {
            size = try await session.objectPropValue(handle, property: PtpObjectProperty.objectSize,
                                                     type: PtpDataType.uint64).integer ?? size
        }
        guard let node = MtpNode.from(handle: handle, info: info, size: size, parentPath: parentPath, timeZone: timeZone) else {
            throw DeviceError.protocolError("Object \(handle) has a name that is not addressable")
        }
        return node
    }
}

/// Groups GetObjectPropList elements by handle into nodes, as they stream in. Android
/// sends all properties of one object before the next; a handle seen again later is
/// ignored. Runs on the MTP link's data callback, one call at a time.
final class PropListAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let parentPath: RemotePath
    /// Android includes the folder itself in a depth-1 listing; it is skipped.
    private let parentHandle: UInt32?
    private let allowed: Set<UInt32>?
    private let timeZone: TimeZone
    private let batchSize: Int
    private let emit: @Sendable ([MtpNode]) -> Void
    private var currentHandle: UInt32?
    private var properties: [UInt16: PtpValue] = [:]
    private var seen: Set<UInt32> = []
    private var nodes: [MtpNode] = []
    private var batch: [MtpNode] = []
    private(set) var emittedCount = 0

    init(parentPath: RemotePath, parentHandle: UInt32?, allowed: Set<UInt32>?, timeZone: TimeZone,
         batchSize: Int, emit: @escaping @Sendable ([MtpNode]) -> Void) {
        self.parentPath = parentPath
        self.parentHandle = parentHandle
        self.allowed = allowed
        self.timeZone = timeZone
        self.batchSize = batchSize
        self.emit = emit
    }

    func consume(_ elements: [PtpPropListElement]) {
        let ready: [[MtpNode]] = lock.withLock {
            var out: [[MtpNode]] = []
            for element in elements {
                if element.handle != currentHandle {
                    if let full = closeCurrent() { out.append(full) }
                    currentHandle = element.handle
                }
                properties[element.property] = element.value
            }
            return out
        }
        ready.forEach(send)
    }

    /// Flushes the last object and returns every node.
    func finish() -> [MtpNode] {
        let (last, all): ([MtpNode]?, [MtpNode]) = lock.withLock {
            let full = closeCurrent()
            let rest = batch.isEmpty ? full : batch
            batch = []
            return (rest, nodes)
        }
        if let last, !last.isEmpty { send(last) }
        return all
    }

    private func send(_ nodes: [MtpNode]) {
        lock.withLock { emittedCount += nodes.count }
        emit(nodes)
    }

    /// Turns the accumulated properties into a node; returns a full batch to emit.
    private func closeCurrent() -> [MtpNode]? {
        defer {
            currentHandle = nil
            properties = [:]
        }
        guard let handle = currentHandle, seen.insert(handle).inserted, handle != parentHandle else { return nil }
        if let allowed, !allowed.contains(handle) { return nil }
        if let parentHandle, let parent = properties[PtpObjectProperty.parentObject]?.integer,
           UInt32(truncatingIfNeeded: parent) != parentHandle {
            return nil // a deeper object, from a device that ignored the depth
        }
        guard let node = MtpNode.from(handle: handle, properties: properties, parentPath: parentPath, timeZone: timeZone) else {
            return nil
        }
        nodes.append(node)
        batch.append(node)
        guard batch.count >= batchSize else { return nil }
        defer { batch = [] }
        return batch
    }
}
