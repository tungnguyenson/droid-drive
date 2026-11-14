import DroidCore
import Foundation

/// Typed wrappers for the operations DroidDrive uses (spec §5.3 table).
public extension MtpSession {
    func storageIDs() async throws -> [UInt32] {
        var reader = PtpReader(try await fetch(.getStorageIDs))
        do { return try reader.u32Array() } catch { throw DeviceError.protocolError("MTP StorageIDs is truncated") }
    }

    func storageInfo(_ storageID: UInt32) async throws -> PtpStorageInfo {
        try PtpStorageInfo.decode(try await fetch(.getStorageInfo, [storageID]))
    }

    /// Handles of the objects directly in `parent` (`PtpHandle.root` for the storage root).
    func objectHandles(storageID: UInt32, parent: UInt32) async throws -> [UInt32] {
        var reader = PtpReader(try await fetch(.getObjectHandles, [storageID, 0, parent]))
        do { return try reader.u32Array() } catch { throw DeviceError.protocolError("MTP ObjectHandles is truncated") }
    }

    func objectInfo(_ handle: UInt32) async throws -> PtpObjectInfo {
        try PtpObjectInfo.decode(try await fetch(.getObjectInfo, [handle]))
    }

    /// GetObjectPropList for every property of `handle` (depth 0) or of its children
    /// (depth 1), decoded as it streams in; `onElements` gets each batch of elements.
    func objectPropList(_ handle: UInt32, depth: UInt32,
                        onElements: @escaping @Sendable ([PtpPropListElement]) throws -> Void) async throws {
        let decoder = StreamingPropList(onElements)
        try await call(.getObjectPropList, [handle, 0, PtpObjectProperty.all, 0, depth], sink: decoder.sink)
        try decoder.finish()
    }

    func objectPropValue(_ handle: UInt32, property: UInt16, type: UInt16) async throws -> PtpValue {
        var reader = PtpReader(try await fetch(.getObjectPropValue, [handle, UInt32(property)]))
        return try reader.value(type: type)
    }

    func setObjectPropValue(_ handle: UInt32, property: UInt16, type: UInt16, value: PtpValue) async throws {
        var writer = PtpWriter()
        try writer.value(value, type: type)
        let data = writer.data
        try await call(.setObjectPropValue, [handle, UInt32(property)],
                       dataOut: (UInt64(data.count), Self.source(data)))
    }

    func deleteObject(_ handle: UInt32) async throws {
        try await call(.deleteObject, [handle, 0])
    }

    /// `parent` is `PtpHandle.noParent` for the storage root here (unlike SendObjectInfo).
    func moveObject(_ handle: UInt32, storageID: UInt32, parent: UInt32) async throws {
        try await call(.moveObject, [handle, storageID, parent])
    }

    func copyObject(_ handle: UInt32, storageID: UInt32, parent: UInt32) async throws -> UInt32 {
        try await call(.copyObject, [handle, storageID, parent]).parameter(0) ?? 0
    }

    /// SendObjectInfo then SendObject, with nothing in between. Returns the new handle.
    /// `parent` is `PtpHandle.root` for the storage root.
    func sendObject(_ info: PtpObjectInfo, storageID: UInt32, parent: UInt32, length: UInt64,
                    source: @escaping PtpDataSource) async throws -> UInt32 {
        let infoData = try info.encoded()
        let isFolder = info.isFolder
        return try await exclusive { runner in
            let response = try await runner.call(.sendObjectInfo, [storageID, parent],
                                                 dataOut: (UInt64(infoData.count), MtpSession.source(infoData)))
            guard let handle = response.parameter(2) else {
                throw DeviceError.protocolError("SendObjectInfo returned no object handle")
            }
            // A folder exists once its ObjectInfo is accepted; no SendObject follows.
            if !isFolder {
                _ = try await runner.call(.sendObject, dataOut: (length, source))
            }
            return handle
        }
    }

    /// Reads `length` bytes at `offset` with Android's GetPartialObject64. Returns the
    /// byte count the device reported.
    func partialObject64(_ handle: UInt32, offset: UInt64, length: UInt32, sink: @escaping PtpDataSink) async throws -> UInt32 {
        let response = try await call(.getPartialObject64,
                                      [handle, UInt32(truncatingIfNeeded: offset), UInt32(truncatingIfNeeded: offset >> 32), length],
                                      sink: sink)
        return response.parameter(0) ?? length
    }

    /// PTP's GetPartialObject: 32-bit offset.
    func partialObject(_ handle: UInt32, offset: UInt32, length: UInt32, sink: @escaping PtpDataSink) async throws -> UInt32 {
        try await call(.getPartialObject, [handle, offset, length], sink: sink).parameter(0) ?? length
    }

    func object(_ handle: UInt32, expectedLength: UInt64?, sink: @escaping PtpDataSink) async throws {
        try await call(.getObject, [handle], sink: sink, expectedDataLength: expectedLength)
    }

    // MARK: Android edit extensions

    func beginEdit(_ handle: UInt32) async throws { try await call(.beginEditObject, [handle]) }
    func endEdit(_ handle: UInt32) async throws { try await call(.endEditObject, [handle]) }

    func truncate(_ handle: UInt32, to size: UInt64) async throws {
        try await call(.truncateObject, [handle, UInt32(truncatingIfNeeded: size), UInt32(truncatingIfNeeded: size >> 32)])
    }

    func sendPartial(_ handle: UInt32, offset: UInt64, length: UInt32, source: @escaping PtpDataSource) async throws {
        try await call(.sendPartialObject,
                       [handle, UInt32(truncatingIfNeeded: offset), UInt32(truncatingIfNeeded: offset >> 32), length],
                       dataOut: (UInt64(length), source))
    }

    /// A data source that sends `data` once.
    static func source(_ data: Data) -> PtpDataSource {
        let box = OnceData(data)
        return { _ in box.take() }
    }
}

private final class OnceData: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(_ data: Data) { self.data = data }
    func take() -> Data? { lock.withLock { defer { data = nil }; return data } }
}

/// Feeds a streaming GetObjectPropList into a `PtpPropListDecoder`.
private final class StreamingPropList: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = PtpPropListDecoder()
    private let onElements: @Sendable ([PtpPropListElement]) throws -> Void

    init(_ onElements: @escaping @Sendable ([PtpPropListElement]) throws -> Void) { self.onElements = onElements }

    var sink: PtpDataSink {
        { [self] chunk in
            let elements = try lock.withLock { () throws -> [PtpPropListElement] in
                decoder.append(chunk)
                return try decoder.drain()
            }
            if !elements.isEmpty { try onElements(elements) }
        }
    }

    func finish() throws {
        let complete = lock.withLock { decoder.isComplete || decoder.announcedCount == nil && decoder.decodedCount == 0 }
        guard complete else { throw DeviceError.protocolError("MTP ObjectPropList ended early") }
    }
}
