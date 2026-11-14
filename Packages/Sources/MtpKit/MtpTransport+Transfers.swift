import DroidCore
import Foundation

/// Reading and writing file data (plan P2-04).
extension MtpTransport {
    // MARK: Read

    public func read(_ path: RemotePath, to fd: FileHandle, range: Range<UInt64>?,
                     progress: Progress) async throws {
        try await mapped(path) {
            try await self.withObject(path) { node in
                guard node.kind == .file else { throw DeviceError.unsupported("Cannot read a folder") }
                let reported = try await self.refresh(node).size
                // 0xFFFFFFFF from ObjectInfo with no ObjectSize to ask: "4 GB or more".
                let size: UInt64? = reported == 0xFFFF_FFFF ? nil : reported
                let end = min(range?.upperBound ?? size ?? .max, size ?? .max)
                let start = min(range?.lowerBound ?? 0, end)
                progress.totalUnitCount = size == nil ? -1 : Int64(end - start)
                let sink = FileSink(fd: fd, progress: progress)
                try await self.readBytes(node.handle, from: start, to: end, fileSize: size, sink: sink)
            }
        }
    }

    /// GetPartialObject64 in 1 MB chunks; GetPartialObject when the range fits 32 bits;
    /// GetObject for the whole file otherwise, keeping only the requested range.
    private func readBytes(_ handle: UInt32, from start: UInt64, to end: UInt64, fileSize: UInt64?,
                           sink: FileSink) async throws {
        let partial64 = session.supports(.getPartialObject64) && fileSize != nil
        let partial32 = session.supports(.getPartialObject) && end <= UInt64(UInt32.max)
        guard partial64 || partial32 else {
            let window = RangeSink(base: sink, start: start, end: end)
            try await session.object(handle, expectedLength: fileSize, sink: window.sink)
            try Task.checkCancellation()
            return
        }
        var offset = start
        while offset < end {
            try Task.checkCancellation()
            let length = UInt32(min(UInt64(Self.readChunk), end - offset))
            let got = partial64
                ? try await session.partialObject64(handle, offset: offset, length: length, sink: sink.sink)
                : try await session.partialObject(handle, offset: UInt32(offset), length: length, sink: sink.sink)
            guard got > 0 else { throw DeviceError.protocolError("The file ended early on the phone") }
            offset += UInt64(got)
        }
    }

    // MARK: Write

    public func write(_ path: RemotePath, from fd: FileHandle, mtime: Date?,
                      progress: Progress) async throws -> RemoteEntry {
        try await mapped(path) {
            let size = try fd.seekToEnd()
            try fd.seek(toOffset: 0)
            guard MtpNode.isAddressable(path.name) else {
                throw DeviceError.invalidName(path.name, reason: "Invalid file name")
            }
            let parent = try await self.locate(path.parent)
            let root = try await self.storageRoot(of: parent, path: path.parent)
            let existing = try await self.lookup(path)
            var replaced: MtpNode?
            if case .object(let node) = existing {
                guard node.kind == .file else { throw DeviceError.exists(path) }
                replaced = node
            }
            let growth = size > (replaced?.size ?? 0) ? size - (replaced?.size ?? 0) : 0
            if growth > Self.freeSpaceCheckThreshold {
                let free = try await self.session.storageInfo(root.id).freeSpace
                if free < growth { throw DeviceError.noSpace(needed: growth, available: free) }
            }
            progress.totalUnitCount = Int64(size)
            progress.completedUnitCount = 0
            let source = FileSource(fd: fd, progress: progress)
            let node: MtpNode
            if let replaced {
                node = try await self.overwrite(replaced, size: size, mtime: mtime, root: root, parent: parent, source: source)
            } else {
                node = try await self.create(path, size: size, mtime: mtime, root: root, parent: parent, source: source)
            }
            return node.entry
        }
    }

    /// The storage a directory location belongs to; virtual folders cannot hold files.
    func storageRoot(of location: Location, path: RemotePath) async throws -> StorageRoot {
        switch location {
        case .virtual: throw DeviceError.permissionDenied(path)
        case .storageRoot(let root): return root
        case .object(let node):
            guard node.kind == .directory else { throw DeviceError.notFound(path) }
            let all = try await roots()
            guard let root = all.first(where: { $0.id == node.storageID })
                    ?? all.first(where: { node.path.isDescendant(of: $0.root) }) else { throw DeviceError.notFound(path) }
            return root
        }
    }

    /// SendObjectInfo's parent: the folder handle, or `PtpHandle.root` at the storage root.
    static func sendParent(_ location: Location) -> UInt32 {
        if case .object(let node) = location { return node.handle }
        return PtpHandle.root
    }

    /// Creates a new file. If the transfer fails half-way, the partial object is removed.
    func create(_ path: RemotePath, size: UInt64, mtime: Date?, root: StorageRoot, parent: Location,
                source: FileSource) async throws -> MtpNode {
        var info = PtpObjectInfo()
        info.storageID = root.id
        info.format = PtpObjectFormat.undefined
        // ObjectInfo's size is 32-bit: 0xFFFFFFFF says "4 GB or more"; the data phase
        // then ends at a short packet (Android's MtpServer handles exactly this).
        info.compressedSize = size >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(size)
        info.parent = Self.sendParent(parent)
        info.filename = path.name
        let stamp = PtpDate.format(mtime ?? Date(), timeZone: timeZone)
        info.dateCreated = stamp
        info.dateModified = stamp
        let handle: UInt32
        do {
            handle = try await session.sendObject(info, storageID: root.id, parent: info.parent, length: size,
                                                  source: source.source)
        } catch {
            // Not in this task: it may be the cancelled one, whose transfers would abort.
            await Task { await self.removeLeftover(path) }.value
            throw error
        }
        let node = try await fetchNode(handle, parentPath: path.parent)
        cache.insert(node)
        return node
    }

    /// After a failed create, deletes whatever object the device kept under the name.
    private func removeLeftover(_ path: RemotePath) async {
        cache.invalidateListing(path.parent)
        guard case .object(let node)? = try? await lookup(path), node.kind == .file else { return }
        try? await session.deleteObject(node.handle)
        cache.remove(path)
    }

    /// Replaces the contents of an existing file.
    ///
    /// With Android's edit extensions the file is rewritten in place (its handle stays;
    /// MTP has no way to set its mtime, so the phone stamps the current time). Without
    /// them the new contents go to a temporary object first and replace the old one only
    /// once complete, so a failed upload never destroys the phone's copy; only a device
    /// that cannot rename falls back to delete-then-write.
    private func overwrite(_ node: MtpNode, size: UInt64, mtime: Date?, root: StorageRoot, parent: Location,
                           source: FileSource) async throws -> MtpNode {
        if PtpOperation.editOperations.allSatisfy(session.supports) {
            try await session.beginEdit(node.handle)
            do {
                var offset: UInt64 = 0
                while offset < size {
                    let length = min(Self.editChunk, size - offset)
                    try await session.sendPartial(node.handle, offset: offset, length: UInt32(length), source: source.source)
                    offset += length
                }
                try await session.truncate(node.handle, to: size)
                try await session.endEdit(node.handle)
            } catch {
                try? await session.endEdit(node.handle)
                throw error
            }
            return try await refresh(node)
        }
        if session.supports(.setObjectPropValue) {
            let temp = node.path.parent.appending(exact: ".droiddrive-\(UUID().uuidString.prefix(8)).tmp")
            let fresh = try await create(temp, size: size, mtime: mtime, root: root, parent: parent, source: source)
            try await session.deleteObject(node.handle)
            cache.remove(node.path)
            try await setName(fresh, node.path.name)
            cache.remove(temp)
            let renamed = try await fetchNode(fresh.handle, parentPath: node.path.parent)
            cache.insert(renamed)
            return renamed
        }
        try await session.deleteObject(node.handle)
        cache.remove(node.path)
        return try await create(node.path, size: size, mtime: mtime, root: root, parent: parent, source: source)
    }

    func setName(_ node: MtpNode, _ name: String) async throws {
        try await session.setObjectPropValue(node.handle, property: PtpObjectProperty.objectFileName,
                                             type: PtpDataType.string, value: .string(name))
    }
}

/// Pulls a local file into a data phase, counting progress. A transfer reads it
/// sequentially, one chunk at a time, so it is never all in memory.
final class FileSource: @unchecked Sendable {
    private let fd: FileHandle
    private let progress: Progress

    init(fd: FileHandle, progress: Progress) {
        self.fd = fd
        self.progress = progress
    }

    var source: PtpDataSource {
        { [self] maxLength in
            try Task.checkCancellation()
            guard let chunk = try fd.read(upToCount: maxLength), !chunk.isEmpty else { return nil }
            progress.completedUnitCount += Int64(chunk.count)
            return chunk
        }
    }
}

/// Writes a data phase to a local file, counting progress.
final class FileSink: @unchecked Sendable {
    private let fd: FileHandle
    private let progress: Progress

    init(fd: FileHandle, progress: Progress) {
        self.fd = fd
        self.progress = progress
    }

    var sink: PtpDataSink {
        { [self] chunk in
            try fd.write(contentsOf: chunk)
            progress.completedUnitCount += Int64(chunk.count)
        }
    }
}

/// Keeps only bytes `start..<end` of a whole-file GetObject.
final class RangeSink: @unchecked Sendable {
    private let lock = NSLock()
    private let base: FileSink
    private let start: UInt64
    private let end: UInt64
    private var position: UInt64 = 0

    init(base: FileSink, start: UInt64, end: UInt64) {
        self.base = base
        self.start = start
        self.end = end
    }

    var sink: PtpDataSink {
        { [self] chunk in
            let slice: Data? = lock.withLock {
                let chunkStart = position
                let chunkEnd = position + UInt64(chunk.count)
                position = chunkEnd
                let lower = max(chunkStart, start)
                let upper = min(chunkEnd, end)
                guard lower < upper else { return nil }
                let from = chunk.startIndex + Int(lower - chunkStart)
                return chunk.subdata(in: from..<from + Int(upper - lower))
            }
            if let slice { try base.sink(slice) }
        }
    }
}
