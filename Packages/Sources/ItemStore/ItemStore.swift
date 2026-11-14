import DroidCore
import Foundation

/// One item as the File Provider extension sees it: a stable id plus the device's
/// current metadata.
public struct StoredItem: Equatable, Sendable {
    public let id: String
    /// nil only for the root.
    public let parentId: String?
    public let path: RemotePath
    public let kind: EntryKind
    public let size: UInt64
    public let mtime: Date
    /// `RemoteEntry.version` at the time it was stored (conflict detection, spec §5.5).
    public let version: String
    public let transportKey: String?
    /// Store generation of the last change that File Provider should hear about.
    public let generation: Int64

    public var name: String { path.name }
}

/// Maps device paths to identifiers that survive renames and moves (spec §5.5, plan
/// P1-10). One store per File Provider domain, in the app group container.
///
/// - Ids are UUIDs, made the first time an item is seen. Renaming or moving updates the
///   path and keeps the id.
/// - Children are matched by NFC name, so an NFD and an NFC spelling are one item.
/// - Every change that File Provider must see bumps a global generation counter;
///   deletions leave a tombstone. `changes(since:)` answers `enumerateChanges`.
///
/// Thread-safe: all calls take one lock. SQLite work is fast compared with the device.
public final class ItemStore: @unchecked Sendable {
    public static let rootId = "root"

    public let root: RemotePath
    private let db: SQLiteDatabase
    private let lock = NSLock()

    /// `url` nil keeps the store in memory (tests).
    public init(url: URL?, root: RemotePath) throws {
        self.root = root
        db = try SQLiteDatabase(path: url?.path)
        try migrate()
    }

    // MARK: Reads

    public var currentGeneration: Int64 {
        lock.withLock { (try? generation()) ?? 0 }
    }

    public func item(id: String) throws -> StoredItem? {
        try lock.withLock {
            try db.query("SELECT \(Self.columns) FROM items WHERE id = ?", [.text(id)], map: Self.decode).first
        }
    }

    public func item(path: RemotePath) throws -> StoredItem? {
        try lock.withLock { try itemLocked(path: path) }
    }

    public func children(of parentId: String) throws -> [StoredItem] {
        try lock.withLock {
            try db.query("SELECT \(Self.columns) FROM items WHERE parent_id = ? ORDER BY name_key",
                         [.text(parentId)], map: Self.decode)
        }
    }

    /// True when the stored version still equals what the caller last saw. Writes and
    /// deletes on the device go ahead only when this holds (spec §12, data-loss risk).
    public func versionMatches(id: String, version: String) throws -> Bool {
        try item(id: id)?.version == version
    }

    /// Directories Finder has opened (listed at least once), shallowest first. Refresh
    /// re-lists only these, never the whole phone (spec §5.5).
    public func listedDirectories() throws -> [StoredItem] {
        try lock.withLock {
            try db.query("SELECT \(Self.columns) FROM items WHERE listed = 1 AND kind = 'directory' ORDER BY length(path)",
                         map: Self.decode)
        }
    }

    /// Items changed and ids deleted after `generation`, plus the generation to use as
    /// the next anchor.
    public func changes(since generation: Int64) throws -> (updated: [StoredItem], deleted: [String], anchor: Int64) {
        try lock.withLock {
            let updated = try db.query("SELECT \(Self.columns) FROM items WHERE generation > ? AND id != ?",
                                       [.int(generation), .text(Self.rootId)], map: Self.decode)
            let deleted = try db.query("SELECT id FROM tombstones WHERE generation > ?", [.int(generation)]) { $0.text(0) ?? "" }
            return (updated, deleted, try self.generation())
        }
    }

    // MARK: Listing

    /// A directory listing in progress. Children not seen by `finishListing` are deleted.
    public struct Listing: Sendable {
        public let parentId: String
        let mark: Int64
    }

    public func beginListing(of parentId: String) throws -> Listing {
        try lock.withLock {
            guard try exists(parentId) else { throw DeviceError.notFound(root) }
            return Listing(parentId: parentId, mark: try nextMark())
        }
    }

    /// Records one batch from `DeviceTransport.list` and returns the stored items, in
    /// the batch's order, with their ids.
    public func apply(_ batch: [RemoteEntry], to listing: Listing) throws -> [StoredItem] {
        try lock.withLock {
            try db.transaction {
                try batch.map { try upsertLocked($0, parentId: listing.parentId, mark: listing.mark) }
            }
        }
    }

    /// Deletes (with tombstones) the children the listing did not see; returns their ids.
    /// Marks the directory as listed, so periodic refresh re-lists it.
    @discardableResult
    public func finishListing(_ listing: Listing) throws -> [String] {
        try lock.withLock {
            try db.transaction {
                try db.run("UPDATE items SET listed = 1 WHERE id = ?", [.text(listing.parentId)])
                let gone = try db.query("SELECT id FROM items WHERE parent_id = ? AND seen_mark != ?",
                                        [.text(listing.parentId), .int(listing.mark)]) { $0.text(0) ?? "" }
                for id in gone { try removeLocked(id) }
                return gone
            }
        }
    }

    // MARK: Writes after device operations

    /// Records an item the extension just created or modified on the device. Keeps the
    /// id of an existing child with the same NFC name.
    @discardableResult
    public func record(_ entry: RemoteEntry, parentId: String) throws -> StoredItem {
        try lock.withLock {
            try db.transaction { try upsertLocked(entry, parentId: parentId, mark: nil) }
        }
    }

    /// Marks a directory for periodic refresh without listing it, for folders made on
    /// the Mac: Finder already knows their contents and never enumerates them, so without
    /// this a file the phone adds there would never show up.
    public func markListed(id: String) throws {
        try lock.withLock { try db.run("UPDATE items SET listed = 1 WHERE id = ? AND kind = 'directory'", [.text(id)]) }
    }

    /// Rename and/or move: updates the item's path and parent, rewrites the paths of
    /// every descendant, keeps all ids.
    @discardableResult
    public func move(id: String, to entry: RemoteEntry, parentId: String) throws -> StoredItem {
        try lock.withLock {
            try db.transaction {
                guard let old = try db.query("SELECT \(Self.columns) FROM items WHERE id = ?", [.text(id)], map: Self.decode).first else {
                    throw DeviceError.notFound(entry.path)
                }
                if let clash = try itemLocked(path: entry.path), clash.id != id {
                    throw DeviceError.exists(entry.path)
                }
                let generation = try bumpGeneration()
                try db.run("""
                    UPDATE items SET parent_id = ?, name_key = ?, path = ?, kind = ?, size = ?, mtime = ?,
                                     version = ?, transport_key = ?, generation = ? WHERE id = ?
                    """, Self.values(entry, parentId: parentId) + [.int(generation), .text(id)])
                if old.kind == .directory {
                    for (childId, childPath) in try descendantsLocked(of: old.path) {
                        let rebased = childPath.replacingPrefix(old.path, with: entry.path)
                        try db.run("UPDATE items SET path = ? WHERE id = ?", [.text(rebased.string), .text(childId)])
                    }
                }
                return try db.query("SELECT \(Self.columns) FROM items WHERE id = ?", [.text(id)], map: Self.decode)[0]
            }
        }
    }

    /// Removes an item and everything under it, leaving tombstones.
    public func remove(id: String) throws {
        try lock.withLock { try db.transaction { try removeLocked(id) } }
    }

    // MARK: Internals

    private static let columns = "id, parent_id, path, kind, size, mtime, version, transport_key, generation"

    private static func decode(_ row: SQLiteDatabase.Row) throws -> StoredItem {
        StoredItem(id: row.text(0) ?? "", parentId: row.text(1),
                   path: RemotePath(exact: row.text(2) ?? "/"),
                   kind: EntryKind(rawValue: row.text(3) ?? "") ?? .other,
                   size: UInt64(bitPattern: row.int(4)),
                   mtime: Date(timeIntervalSince1970: row.real(5)),
                   version: row.text(6) ?? "", transportKey: row.text(7),
                   generation: row.int(8))
    }

    /// parent_id, name_key, path, kind, size, mtime, version, transport_key
    private static func values(_ entry: RemoteEntry, parentId: String) -> [SQLiteDatabase.Value] {
        [.text(parentId), .text(FileName.normalized(entry.name)), .text(entry.path.string),
         .text(entry.kind.rawValue), .int(Int64(bitPattern: entry.size)),
         .real(entry.mtime.timeIntervalSince1970), .text(entry.version),
         entry.transportKey.map { .text($0) } ?? .null]
    }

    private func migrate() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                parent_id TEXT REFERENCES items(id),
                name_key TEXT NOT NULL,
                path TEXT NOT NULL,
                kind TEXT NOT NULL,
                size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                version TEXT NOT NULL,
                transport_key TEXT,
                generation INTEGER NOT NULL,
                seen_mark INTEGER NOT NULL DEFAULT 0,
                listed INTEGER NOT NULL DEFAULT 0
            );
            CREATE UNIQUE INDEX IF NOT EXISTS items_parent_name ON items(parent_id, name_key);
            CREATE INDEX IF NOT EXISTS items_path ON items(path);
            CREATE INDEX IF NOT EXISTS items_generation ON items(generation);
            CREATE TABLE IF NOT EXISTS tombstones (id TEXT PRIMARY KEY, generation INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            INSERT OR IGNORE INTO meta (key, value) VALUES ('generation', 0), ('mark', 0);
            """)
        try db.run("""
            INSERT OR IGNORE INTO items (id, parent_id, name_key, path, kind, size, mtime, version, generation)
            VALUES (?, NULL, '', ?, 'directory', 0, 0, '', 0)
            """, [.text(Self.rootId), .text(root.string)])
    }

    private func generation() throws -> Int64 {
        try db.query("SELECT value FROM meta WHERE key = 'generation'") { $0.int(0) }.first ?? 0
    }

    private func bumpGeneration() throws -> Int64 {
        try db.run("UPDATE meta SET value = value + 1 WHERE key = 'generation'")
        return try generation()
    }

    private func nextMark() throws -> Int64 {
        try db.run("UPDATE meta SET value = value + 1 WHERE key = 'mark'")
        return try db.query("SELECT value FROM meta WHERE key = 'mark'") { $0.int(0) }.first ?? 0
    }

    private func exists(_ id: String) throws -> Bool {
        try !db.query("SELECT 1 FROM items WHERE id = ?", [.text(id)]) { $0.int(0) }.isEmpty
    }

    private func itemLocked(path: RemotePath) throws -> StoredItem? {
        if path == root { return try db.query("SELECT \(Self.columns) FROM items WHERE id = ?", [.text(Self.rootId)], map: Self.decode).first }
        guard path.isDescendant(of: root), !path.isRoot else { return nil }
        // Paths are stored with device bytes; match the parent by path, the name by NFC key.
        guard let parent = try itemLocked(path: path.parent) else { return nil }
        return try db.query("SELECT \(Self.columns) FROM items WHERE parent_id = ? AND name_key = ?",
                            [.text(parent.id), .text(FileName.normalized(path.name))], map: Self.decode).first
    }

    private func upsertLocked(_ entry: RemoteEntry, parentId: String, mark: Int64?) throws -> StoredItem {
        let key = FileName.normalized(entry.name)
        let existing = try db.query("SELECT \(Self.columns) FROM items WHERE parent_id = ? AND name_key = ?",
                                    [.text(parentId), .text(key)], map: Self.decode).first
        if let existing {
            let changed = existing.version != entry.version || existing.kind != entry.kind
                || Array(existing.path.string.utf8) != Array(entry.path.string.utf8)
            let generation = changed ? try bumpGeneration() : existing.generation
            if existing.kind == .directory && entry.kind != .directory {
                try removeDescendantsLocked(of: existing.path)
            }
            try db.run("""
                UPDATE items SET parent_id = ?, name_key = ?, path = ?, kind = ?, size = ?, mtime = ?,
                                 version = ?, transport_key = ?, generation = ?,
                                 seen_mark = COALESCE(?, seen_mark) WHERE id = ?
                """, Self.values(entry, parentId: parentId)
                    + [.int(generation), mark.map { .int($0) } ?? .null, .text(existing.id)])
            return StoredItem(id: existing.id, parentId: parentId, path: entry.path, kind: entry.kind,
                              size: entry.size, mtime: entry.mtime, version: entry.version,
                              transportKey: entry.transportKey, generation: generation)
        }
        let id = UUID().uuidString
        let generation = try bumpGeneration()
        try db.run("""
            INSERT INTO items (parent_id, name_key, path, kind, size, mtime, version, transport_key, generation, seen_mark, id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, Self.values(entry, parentId: parentId) + [.int(generation), .int(mark ?? 0), .text(id)])
        try db.run("DELETE FROM tombstones WHERE id = ?", [.text(id)])
        return StoredItem(id: id, parentId: parentId, path: entry.path, kind: entry.kind, size: entry.size,
                          mtime: entry.mtime, version: entry.version, transportKey: entry.transportKey,
                          generation: generation)
    }

    /// Ids and paths strictly below `path`. Uses a byte range on the path index:
    /// "/" is 0x2F and "0" is 0x30, so [p + "/", p + "0") is exactly the subtree.
    private func descendantsLocked(of path: RemotePath) throws -> [(String, RemotePath)] {
        let prefix = path.isRoot ? "" : path.string
        return try db.query("SELECT id, path FROM items WHERE path >= ? AND path < ? AND id != ?",
                            [.text(prefix + "/"), .text(prefix + "0"), .text(Self.rootId)]) {
            ($0.text(0) ?? "", RemotePath(exact: $0.text(1) ?? "/"))
        }
    }

    private func removeLocked(_ id: String) throws {
        guard id != Self.rootId else { return }
        guard let item = try db.query("SELECT \(Self.columns) FROM items WHERE id = ?", [.text(id)], map: Self.decode).first else { return }
        try removeDescendantsLocked(of: item.path)
        try tombstone(id)
    }

    /// Deepest first, so no remaining row's parent_id points at a deleted row.
    private func removeDescendantsLocked(of path: RemotePath) throws {
        let below = try descendantsLocked(of: path).sorted { $0.1.string.utf8.count > $1.1.string.utf8.count }
        for (childId, _) in below { try tombstone(childId) }
    }

    private func tombstone(_ id: String) throws {
        let generation = try bumpGeneration()
        try db.run("DELETE FROM items WHERE id = ?", [.text(id)])
        try db.run("INSERT OR REPLACE INTO tombstones (id, generation) VALUES (?, ?)", [.text(id), .int(generation)])
    }
}
