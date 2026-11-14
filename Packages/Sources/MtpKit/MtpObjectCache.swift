import DroidCore
import Foundation

/// One object on the device as MtpTransport knows it.
struct MtpNode: Hashable, Sendable {
    let handle: UInt32
    let storageID: UInt32
    /// Parent handle; `PtpHandle.noParent` at the storage root.
    let parent: UInt32
    let path: RemotePath
    let kind: EntryKind
    let size: UInt64
    let mtime: Date

    var entry: RemoteEntry {
        RemoteEntry(path: path, kind: kind, size: kind == .directory ? 0 : size, mtime: mtime,
                    transportKey: String(handle))
    }

    func moved(to newPath: RemotePath) -> MtpNode {
        MtpNode(handle: handle, storageID: storageID, parent: parent, path: newPath, kind: kind, size: size, mtime: mtime)
    }

    /// A name the device reported that cannot be part of a path. Such objects are
    /// skipped: they could never be addressed again.
    static func isAddressable(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Builds a node from GetObjectPropList properties.
    static func from(handle: UInt32, properties: [UInt16: PtpValue], parentPath: RemotePath,
                     timeZone: TimeZone) -> MtpNode? {
        guard let name = properties[PtpObjectProperty.objectFileName]?.string, isAddressable(name) else { return nil }
        let format = UInt16(truncatingIfNeeded: properties[PtpObjectProperty.objectFormat]?.integer ?? UInt64(PtpObjectFormat.undefined))
        let modified = properties[PtpObjectProperty.dateModified]?.string
        let created = properties[PtpObjectProperty.dateCreated]?.string
        let mtime = [modified, created].lazy.compactMap { $0.flatMap { PtpDate.parse($0, timeZone: timeZone) } }.first
        return MtpNode(handle: handle,
                       storageID: UInt32(truncatingIfNeeded: properties[PtpObjectProperty.storageID]?.integer ?? 0),
                       parent: UInt32(truncatingIfNeeded: properties[PtpObjectProperty.parentObject]?.integer ?? 0),
                       path: parentPath.appending(exact: name),
                       kind: format == PtpObjectFormat.association ? .directory : .file,
                       size: properties[PtpObjectProperty.objectSize]?.integer ?? 0,
                       mtime: mtime ?? Date(timeIntervalSince1970: 0))
    }

    /// Builds a node from ObjectInfo; `size` is the real size when ObjectInfo says
    /// 0xFFFFFFFF (a file of 4 GB or more).
    static func from(handle: UInt32, info: PtpObjectInfo, size: UInt64, parentPath: RemotePath,
                     timeZone: TimeZone) -> MtpNode? {
        guard isAddressable(info.filename) else { return nil }
        let mtime = PtpDate.parse(info.dateModified, timeZone: timeZone) ?? PtpDate.parse(info.dateCreated, timeZone: timeZone)
        return MtpNode(handle: handle, storageID: info.storageID, parent: info.parent,
                       path: parentPath.appending(exact: info.filename),
                       kind: info.isFolder ? .directory : .file, size: size,
                       mtime: mtime ?? Date(timeIntervalSince1970: 0))
    }
}

/// Byte-exact path key. `RemotePath ==` compares strings canonically (NFC equals NFD),
/// but on the device two names that differ only in normalization are two files.
struct PathKey: Hashable, Sendable {
    let bytes: [UInt8]
    init(_ path: RemotePath) { bytes = Array(path.string.utf8) }
}

/// Path ↔ handle map for one session (spec §5.3: handles are only valid within a
/// session, so this is rebuilt on demand and never persisted).
struct MtpObjectCache {
    /// How long a complete listing is trusted to say "this name does not exist". Device
    /// events normally keep it right; the limit covers phones that send none.
    static let negativeLifetime: TimeInterval = 10

    private var byHandle: [UInt32: MtpNode] = [:]
    private var byPath: [PathKey: UInt32] = [:]
    /// Children of directories listed completely, and when.
    private var children: [PathKey: Set<UInt32>] = [:]
    private var listedAt: [PathKey: Date] = [:]

    func node(at path: RemotePath) -> MtpNode? { byPath[PathKey(path)].flatMap { byHandle[$0] } }
    func node(handle: UInt32) -> MtpNode? { byHandle[handle] }

    /// True when `dir` was listed recently enough to trust a missing name.
    func isFreshlyListed(_ dir: RemotePath, now: Date = Date()) -> Bool {
        guard let at = listedAt[PathKey(dir)] else { return false }
        return now.timeIntervalSince(at) < Self.negativeLifetime
    }

    mutating func insert(_ node: MtpNode) {
        if let old = byHandle[node.handle], PathKey(old.path) != PathKey(node.path) {
            remove(old.path)
        }
        if let other = byPath[PathKey(node.path)], other != node.handle {
            byHandle[other] = nil
        }
        byHandle[node.handle] = node
        byPath[PathKey(node.path)] = node.handle
        let parentKey = PathKey(node.path.parent)
        if children[parentKey] != nil { children[parentKey]!.insert(node.handle) }
    }

    /// Replaces what is known about `dir`'s children with a complete listing.
    mutating func setChildren(of dir: RemotePath, _ nodes: [MtpNode], now: Date = Date()) {
        let key = PathKey(dir)
        let fresh = Set(nodes.map(\.handle))
        for handle in children[key] ?? [] where !fresh.contains(handle) {
            if let gone = byHandle[handle] { remove(gone.path) }
        }
        children[key] = []
        nodes.forEach { insert($0) }
        listedAt[key] = now
    }

    /// Forgets `path` and everything below it.
    mutating func remove(_ path: RemotePath) {
        let key = PathKey(path)
        if let handle = byPath.removeValue(forKey: key) {
            byHandle[handle] = nil
            children[PathKey(path.parent)]?.remove(handle)
        }
        if let kids = children.removeValue(forKey: key) {
            for handle in kids {
                if let child = byHandle[handle] { remove(child.path) }
            }
        }
        listedAt[key] = nil
    }

    /// Forgets that `dir` was listed, so the next lookup asks the device.
    mutating func invalidateListing(_ dir: RemotePath) {
        listedAt[PathKey(dir)] = nil
    }

    mutating func removeAll() { self = MtpObjectCache() }

    var count: Int { byHandle.count }
}
