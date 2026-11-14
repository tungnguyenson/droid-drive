import DroidCore
import Foundation

/// Folder operations (plan P2-05) and device events (plan P2-06).
extension MtpTransport {
    // MARK: mkdir

    public func mkdir(_ path: RemotePath) async throws -> RemoteEntry {
        try await mapped(path) { try await self.makeDirectory(path).entry }
    }

    private func makeDirectory(_ path: RemotePath) async throws -> MtpNode {
        if let existing = try await lookup(path) {
            guard case .object(let node) = existing else {
                // A storage root or a folder above it: already a directory, not an object.
                return MtpNode(handle: 0, storageID: 0, parent: 0, path: path, kind: .directory, size: 0,
                               mtime: Date(timeIntervalSince1970: 0))
            }
            guard node.kind == .directory else { throw DeviceError.exists(path) }
            return node
        }
        guard MtpNode.isAddressable(path.name) else { throw DeviceError.invalidName(path.name, reason: "Invalid file name") }
        // `mkdir -p`, like AdbTransport.
        let parent: Location
        if let found = try await lookup(path.parent) {
            parent = found
        } else {
            _ = try await makeDirectory(path.parent)
            parent = try await locate(path.parent)
        }
        let root = try await storageRoot(of: parent, path: path.parent)
        var info = PtpObjectInfo()
        info.storageID = root.id
        info.format = PtpObjectFormat.association
        info.associationType = PtpObjectFormat.genericFolder
        info.parent = Self.sendParent(parent)
        info.filename = path.name
        info.dateModified = PtpDate.format(Date(), timeZone: timeZone)
        let handle = try await session.sendObject(info, storageID: root.id, parent: info.parent, length: 0,
                                                  source: { _ in nil })
        let node = try await fetchNode(handle, parentPath: path.parent)
        cache.insert(node)
        return node
    }

    // MARK: delete

    public func delete(_ path: RemotePath, recursive: Bool) async throws {
        try await mapped(path) {
            try await self.withObject(path) { node in
                if node.kind == .directory && !recursive {
                    let children = try await self.listChildren(of: .object(node), at: path, emit: { _ in })
                    if !children.isEmpty { throw DeviceError.protocolError("Folder is not empty") }
                }
                // DeleteObject removes a folder with everything in it.
                try await self.session.deleteObject(node.handle)
                self.cache.remove(path)
            }
        }
    }

    // MARK: rename / move

    public func rename(_ from: RemotePath, to: RemotePath) async throws -> RemoteEntry {
        try await mapped(from) {
            try await self.withObject(from) { node in
                if try await self.lookup(to) != nil { throw DeviceError.exists(to) }
                guard MtpNode.isAddressable(to.name) else { throw DeviceError.invalidName(to.name, reason: "Invalid file name") }
                if to.isDescendant(of: from) { throw DeviceError.protocolError("Cannot move a folder into itself") }
                guard let parent = try await self.lookup(to.parent), parent.isDirectory else {
                    throw DeviceError.notFound(to.parent)
                }
                let root = try await self.storageRoot(of: parent, path: to.parent)
                let moved: MtpNode
                if PathKey(from.parent) == PathKey(to.parent) {
                    moved = try await self.renameInPlace(node, to: to)
                } else if self.session.supports(.moveObject) {
                    moved = try await self.move(node, to: to, parent: parent, root: root)
                } else {
                    moved = try await self.moveByCopy(node, to: to)
                }
                return moved.entry
            }
        }
    }

    private func renameInPlace(_ node: MtpNode, to: RemotePath) async throws -> MtpNode {
        guard session.supports(.setObjectPropValue) else { return try await moveByCopy(node, to: to) }
        try await setName(node, to.name)
        cache.remove(node.path)
        let fresh = try await fetchNode(node.handle, parentPath: to.parent)
        cache.insert(fresh)
        return fresh
    }

    /// MoveObject keeps the name, so a move that also renames needs a second step. When
    /// the old name is taken in the destination, the object gets a temporary name first.
    private func move(_ node: MtpNode, to: RemotePath, parent: Location, root: StorageRoot) async throws -> MtpNode {
        var current = node
        let sameName = Array(node.path.name.utf8) == Array(to.name.utf8)
        if !sameName, try await lookup(to.parent.appending(exact: node.path.name)) != nil {
            let temp = node.path.parent.appending(exact: ".droiddrive-\(UUID().uuidString.prefix(8))")
            current = try await renameInPlace(current, to: temp)
        }
        let target: UInt32 = { if case .object(let dir) = parent { return dir.handle } else { return PtpHandle.noParent } }()
        try await session.moveObject(current.handle, storageID: root.id, parent: target)
        cache.remove(current.path)
        var fresh = try await fetchNode(current.handle, parentPath: to.parent)
        cache.insert(fresh)
        if !sameName { fresh = try await renameInPlace(fresh, to: to) }
        return fresh
    }

    /// Copy then delete, for phones without MoveObject (spec §5.3: slow, the UI says so).
    private func moveByCopy(_ node: MtpNode, to: RemotePath) async throws -> MtpNode {
        if node.kind == .directory {
            let created = try await makeDirectory(to)
            let children = try await listChildren(of: .object(node), at: node.path, emit: { _ in })
            for child in children {
                _ = try await moveByCopy(child, to: to.appending(exact: child.path.name))
            }
            try await session.deleteObject(node.handle)
            cache.remove(node.path)
            return created
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("droiddrive-mtp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let out = try FileHandle(forWritingTo: temp)
        try await read(node.path, to: out, range: nil, progress: Progress())
        try out.close()
        let input = try FileHandle(forReadingFrom: temp)
        defer { try? input.close() }
        let entry = try await write(to, from: input, mtime: node.mtime, progress: Progress())
        try await session.deleteObject(node.handle)
        cache.remove(node.path)
        guard let created = cache.node(at: entry.path) else { return try await withObject(to) { $0 } }
        return created
    }

    // MARK: Events

    /// Turns a device event into a `ChangeHint` and keeps the cache current (P2-06).
    func handle(_ event: PtpEvent) async {
        let handle = event.parameters.first ?? 0
        switch event.code {
        case .objectAdded:
            await objectAdded(handle)
        case .objectRemoved:
            if let node = cache.node(handle: handle) {
                cache.remove(node.path)
                changesContinuation.yield(.changed(node.path.parent))
            } else {
                changesContinuation.yield(.changed(.root))
            }
        case .objectInfoChanged, .objectPropChanged:
            guard let node = cache.node(handle: handle) else { return }
            if let fresh = try? await fetchNode(handle, parentPath: node.path.parent) {
                cache.insert(fresh)
            }
            changesContinuation.yield(.changed(node.path.parent))
        case .storeAdded, .storeRemoved:
            storageRoots = nil
            cache.removeAll()
            changesContinuation.yield(.storagesChanged)
        default:
            break
        }
    }

    private func objectAdded(_ handle: UInt32) async {
        if let known = cache.node(handle: handle) {
            changesContinuation.yield(.changed(known.path.parent))
            return
        }
        do {
            let info = try await session.objectInfo(handle)
            let parentPath: RemotePath?
            if info.parent == PtpHandle.noParent || info.parent == PtpHandle.root {
                parentPath = try await roots().first { $0.id == info.storageID }?.root
            } else {
                parentPath = cache.node(handle: info.parent)?.path
            }
            guard let parentPath else {
                // Somewhere not yet browsed: say which storage changed.
                let root = try await roots().first { $0.id == info.storageID }?.root ?? .root
                changesContinuation.yield(.changed(root))
                return
            }
            if cache.isFreshlyListed(parentPath) || cache.node(at: parentPath) != nil {
                if let node = try? await fetchNode(handle, parentPath: parentPath) { cache.insert(node) }
            }
            changesContinuation.yield(.changed(parentPath))
        } catch {
            changesContinuation.yield(.changed(.root))
        }
    }
}
