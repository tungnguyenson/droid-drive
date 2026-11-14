import Foundation

/// In-memory `DeviceTransport` for tests and for the File Provider spike (S0-c).
/// Behaves like a well-behaved device: NFC names, no overwrite on rename, `exists`
/// on mkdir over a file. `setConnected(false)` simulates pulling the cable.
public actor FakeTransport: DeviceTransport {
    private struct Node {
        var kind: EntryKind
        var data: Data
        var mtime: Date
    }

    public nonisolated let info: DeviceInfo
    public nonisolated let changes: AsyncStream<ChangeHint>
    private let changesContinuation: AsyncStream<ChangeHint>.Continuation
    private let storageRoot: RemotePath
    private let capacity: UInt64
    private let batchSize: Int
    private var nodes: [RemotePath: Node]
    private var connected = true

    public init(info: DeviceInfo = DeviceInfo(serial: "FAKE0001", manufacturer: "Fake",
                                              model: "Fake Phone", androidVersion: "16"),
                storageRoot: RemotePath = RemotePath("/storage/emulated/0"),
                capacity: UInt64 = 64 << 30,
                batchSize: Int = 500) {
        self.info = info
        self.storageRoot = storageRoot
        self.capacity = capacity
        self.batchSize = batchSize
        var initial: [RemotePath: Node] = [:]
        var path = storageRoot
        while true {
            initial[path] = Node(kind: .directory, data: Data(), mtime: Date(timeIntervalSince1970: 0))
            if path.isRoot { break }
            path = path.parent
        }
        self.nodes = initial
        (self.changes, self.changesContinuation) = AsyncStream.makeStream()
    }

    // MARK: Test controls

    public func setConnected(_ value: Bool) { connected = value }

    /// Creates or replaces a file directly, as if the phone wrote it, and emits a hint.
    public func seedFile(_ path: RemotePath, contents: Data, mtime: Date = Date()) {
        ensureParents(of: path, mtime: mtime)
        nodes[path] = Node(kind: .file, data: contents, mtime: mtime)
        changesContinuation.yield(.changed(path.parent))
    }

    public func seedDirectory(_ path: RemotePath) {
        ensureParents(of: path, mtime: Date())
        nodes[path] = Node(kind: .directory, data: Data(), mtime: Date())
    }

    public func contents(of path: RemotePath) -> Data? { nodes[path]?.data }

    // MARK: DeviceTransport

    public func storages() throws -> [StorageInfo] {
        try requireConnection()
        let used = nodes.values.reduce(UInt64(0)) { $0 + UInt64($1.data.count) }
        return [StorageInfo(id: storageRoot.string, kind: .internal, root: storageRoot,
                            capacity: capacity, free: capacity - min(used, capacity))]
    }

    public nonisolated func list(_ dir: RemotePath) -> AsyncThrowingStream<[RemoteEntry], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let entries = try await self.children(of: dir)
                    for start in stride(from: 0, to: entries.count, by: self.batchSize) {
                        continuation.yield(Array(entries[start..<min(start + self.batchSize, entries.count)]))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stat(_ path: RemotePath) throws -> RemoteEntry {
        try requireConnection()
        guard let node = nodes[path] else { throw DeviceError.notFound(path) }
        return entry(path, node)
    }

    public func read(_ path: RemotePath, to fd: FileHandle, range: Range<UInt64>?,
                     progress: Progress) throws {
        try requireConnection()
        guard let node = nodes[path] else { throw DeviceError.notFound(path) }
        guard node.kind == .file else { throw DeviceError.unsupported("Cannot read a folder") }
        let bytes: Data
        if let range {
            let upper = min(Int(range.upperBound), node.data.count)
            let lower = min(Int(range.lowerBound), upper)
            bytes = node.data.subdata(in: lower..<upper)
        } else {
            bytes = node.data
        }
        progress.totalUnitCount = Int64(bytes.count)
        try fd.write(contentsOf: bytes)
        progress.completedUnitCount = Int64(bytes.count)
    }

    public func write(_ path: RemotePath, from fd: FileHandle, mtime: Date?,
                      progress: Progress) throws -> RemoteEntry {
        try requireConnection()
        try requireParentDirectory(of: path)
        if nodes[path]?.kind == .directory { throw DeviceError.exists(path) }
        try fd.seek(toOffset: 0)
        let data = try fd.readToEnd() ?? Data()
        let free = try storages().first?.free ?? 0
        if UInt64(data.count) > free { throw DeviceError.noSpace(needed: UInt64(data.count), available: free) }
        let node = Node(kind: .file, data: data, mtime: mtime ?? Date())
        nodes[path] = node
        progress.totalUnitCount = Int64(data.count)
        progress.completedUnitCount = Int64(data.count)
        return entry(path, node)
    }

    public func mkdir(_ path: RemotePath) throws -> RemoteEntry {
        try requireConnection()
        if let existing = nodes[path] {
            guard existing.kind == .directory else { throw DeviceError.exists(path) }
            return entry(path, existing)
        }
        ensureParents(of: path, mtime: Date())
        let node = Node(kind: .directory, data: Data(), mtime: Date())
        nodes[path] = node
        return entry(path, node)
    }

    public func delete(_ path: RemotePath, recursive: Bool) throws {
        try requireConnection()
        guard nodes[path] != nil else { throw DeviceError.notFound(path) }
        let descendants = nodes.keys.filter { $0 != path && $0.isDescendant(of: path) }
        if !recursive && !descendants.isEmpty {
            throw DeviceError.protocolError("Folder is not empty")
        }
        descendants.forEach { nodes[$0] = nil }
        nodes[path] = nil
    }

    public func rename(_ from: RemotePath, to: RemotePath) throws -> RemoteEntry {
        try requireConnection()
        guard nodes[from] != nil else { throw DeviceError.notFound(from) }
        if nodes[to] != nil { throw DeviceError.exists(to) }
        try requireParentDirectory(of: to)
        let moved = nodes.filter { $0.key.isDescendant(of: from) }
        moved.keys.forEach { nodes[$0] = nil }
        for (path, node) in moved {
            nodes[path.replacingPrefix(from, with: to)] = node
        }
        return entry(to, nodes[to]!)
    }

    // MARK: Helpers

    private func children(of dir: RemotePath) throws -> [RemoteEntry] {
        try requireConnection()
        guard let node = nodes[dir] else { throw DeviceError.notFound(dir) }
        guard node.kind == .directory else { throw DeviceError.unsupported("\(dir) is not a folder") }
        return nodes
            .filter { $0.key != dir && $0.key.parent == dir }
            .map { entry($0.key, $0.value) }
            .sorted { $0.path < $1.path }
    }

    private func requireConnection() throws {
        guard connected else { throw DeviceError.disconnected }
    }

    private func requireParentDirectory(of path: RemotePath) throws {
        guard nodes[path.parent]?.kind == .directory else { throw DeviceError.notFound(path.parent) }
    }

    private func ensureParents(of path: RemotePath, mtime: Date) {
        var parent = path.parent
        while nodes[parent] == nil {
            nodes[parent] = Node(kind: .directory, data: Data(), mtime: mtime)
            parent = parent.parent
        }
    }

    private func entry(_ path: RemotePath, _ node: Node) -> RemoteEntry {
        RemoteEntry(path: path, kind: node.kind,
                    size: node.kind == .file ? UInt64(node.data.count) : 0,
                    mtime: node.mtime)
    }
}
