import DroidCore
import Foundation

/// `DeviceTransport` over ADB (plan P1-09): file data via the sync service, directory
/// changes via `shell,v2`, both on whatever `AdbServiceOpener` reaches the device (a
/// direct `AdbConnection` over USB/TCP, or the user's adb server).
public final class AdbTransport: DeviceTransport {
    public static let listBatchSize = 500
    public static let maxConcurrentTransfers = 4
    /// Writes larger than this check free space first (spec §5.6).
    public static let freeSpaceCheckThreshold: UInt64 = 100 << 20
    static let readChunk = 1 << 20
    /// Exit code our rename script uses for "destination exists".
    static let existsExitCode: Int32 = 17

    public let info: DeviceInfo
    /// ADB has no change events; the layer above refreshes on a timer.
    public let changes: AsyncStream<ChangeHint>
    let opener: any AdbServiceOpener
    private let transfers = AsyncSemaphore(AdbTransport.maxConcurrentTransfers)

    init(opener: any AdbServiceOpener, info: DeviceInfo) {
        self.opener = opener
        self.info = info
        self.changes = AsyncStream { $0.finish() }
    }

    /// Reads the device's identity and returns a ready transport.
    public static func connect(_ opener: any AdbServiceOpener, fallbackSerial: String = "") async throws -> AdbTransport {
        let result = try await ShellRunner.run(
            "getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release; getprop ro.serialno",
            on: opener)
        let lines = result.stdoutText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func line(_ i: Int) -> String { i < lines.count ? lines[i] : "" }
        let serial = line(3).isEmpty ? fallbackSerial : line(3)
        let info = DeviceInfo(serial: serial, manufacturer: line(0), model: line(1),
                              androidVersion: line(2).isEmpty ? nil : line(2))
        return AdbTransport(opener: opener, info: info)
    }

    // MARK: Storages

    /// Internal storage plus every mounted SD card (`/storage/XXXX-XXXX`), with sizes
    /// from `df -k`. The script has no user input in it.
    public func storages() async throws -> [StorageInfo] {
        let script = #"for d in /storage/emulated/0 /storage/*-*; do [ -d "$d" ] && df -k "$d" | tail -n 1 | sed "s|^|$d\#t|"; done"#
        let result = try await shell(script)
        return Self.parseStorages(result.stdoutText)
    }

    static func parseStorages(_ text: String) -> [StorageInfo] {
        text.split(separator: "\n").compactMap { line in
            let halves = line.split(separator: "\t", maxSplits: 1)
            guard halves.count == 2 else { return nil }
            let fields = halves[1].split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, let blocks = UInt64(fields[1]), let available = UInt64(fields[3]) else { return nil }
            let root = RemotePath(exact: String(halves[0]))
            return StorageInfo(id: root.string,
                               kind: root.string == "/storage/emulated/0" ? .internal : .removable,
                               root: root, capacity: blocks * 1024, free: available * 1024)
        }
    }

    // MARK: Listing

    public func list(_ dir: RemotePath) -> AsyncThrowingStream<[RemoteEntry], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.withSync { sync in
                        let stat = try await sync.stat(dir)
                        try Self.require(stat, dir)
                        guard stat.kind == .directory else { throw DeviceError.unsupported("\(dir) is not a folder") }
                        var batch: [RemoteEntry] = []
                        batch.reserveCapacity(Self.listBatchSize)
                        try await sync.list(dir) { name, stat in
                            batch.append(Self.entry(dir.appending(exact: name), stat))
                            if batch.count == Self.listBatchSize {
                                continuation.yield(batch)
                                batch.removeAll(keepingCapacity: true)
                            }
                        }
                        if !batch.isEmpty { continuation.yield(batch) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteEntry {
        try await withSync { sync in try await Self.statEntry(path, sync) }
    }

    // MARK: Transfers

    public func read(_ path: RemotePath, to fd: FileHandle, range: Range<UInt64>?,
                     progress: Progress) async throws {
        guard range == nil else {
            throw DeviceError.unsupported("Ranged reads over ADB (exec:dd) are only needed for FSKit and not implemented")
        }
        try await transfers.withPermit {
            try await self.withSync { sync in
                let entry = try await Self.statEntry(path, sync)
                guard entry.kind == .file else { throw DeviceError.unsupported("\(path) is not a file") }
                progress.totalUnitCount = Int64(entry.size)
                try await sync.pull(path) { chunk in
                    try Task.checkCancellation()
                    try fd.write(contentsOf: chunk)
                    progress.completedUnitCount += Int64(chunk.count)
                }
            }
        }
    }

    public func write(_ path: RemotePath, from fd: FileHandle, mtime: Date?,
                      progress: Progress) async throws -> RemoteEntry {
        let size = try fd.seekToEnd()
        try fd.seek(toOffset: 0)
        let existing = try await withSync { try await $0.stat(path) }
        if existing.exists && existing.kind == .directory { throw DeviceError.exists(path) }
        // Overwriting frees the old file's blocks, so only the growth needs room.
        let replaced = existing.exists && existing.kind == .file ? existing.size : 0
        let growth = size > replaced ? size - replaced : 0
        if growth > Self.freeSpaceCheckThreshold {
            try await requireFreeSpace(growth, near: path)
        }
        let seconds = Int64((mtime ?? Date()).timeIntervalSince1970)
        return try await transfers.withPermit {
            try await self.withSync { sync in
                progress.totalUnitCount = Int64(size)
                try await sync.push(path, mode: 0o100644, mtime: seconds) {
                    try Task.checkCancellation()
                    let chunk = try fd.read(upToCount: Self.readChunk)
                    if let chunk { progress.completedUnitCount += Int64(chunk.count) }
                    return chunk
                }
                return try await Self.statEntry(path, sync)
            }
        }
    }

    private func requireFreeSpace(_ needed: UInt64, near path: RemotePath) async throws {
        let storages = try await storages()
        guard let storage = storages.filter({ path.isDescendant(of: $0.root) })
            .max(by: { $0.root.string.count < $1.root.string.count }) else { return }
        if storage.free < needed { throw DeviceError.noSpace(needed: needed, available: storage.free) }
    }

    // MARK: Directory operations

    public func mkdir(_ path: RemotePath) async throws -> RemoteEntry {
        let existing = try await withSync { try await $0.stat(path) }
        if existing.exists {
            guard existing.kind == .directory else { throw DeviceError.exists(path) }
            return Self.entry(path, existing)
        }
        try check(try await shell("mkdir -p -- \(ShellQuote.quote(path))"), path)
        return try await stat(path)
    }

    public func delete(_ path: RemotePath, recursive: Bool) async throws {
        let entry = try await stat(path)
        let q = ShellQuote.quote(path)
        let command: String
        if recursive {
            command = "rm -rf -- \(q)"
        } else {
            command = entry.kind == .directory ? "rmdir -- \(q)" : "rm -f -- \(q)"
        }
        try check(try await shell(command), path)
    }

    public func rename(_ from: RemotePath, to: RemotePath) async throws -> RemoteEntry {
        _ = try await stat(from)
        let target = ShellQuote.quote(to)
        let script = "if [ -e \(target) ] || [ -L \(target) ]; then exit \(Self.existsExitCode); fi; mv -- \(ShellQuote.quote(from)) \(target)"
        let result = try await shell(script)
        if result.exitCode == Self.existsExitCode { throw DeviceError.exists(to) }
        try check(result, to)
        return try await stat(to)
    }

    // MARK: Helpers

    func shell(_ command: String) async throws -> ShellResult {
        try await ShellRunner.run(command, on: opener)
    }

    private func check(_ result: ShellResult, _ path: RemotePath) throws {
        guard result.exitCode != 0 else { return }
        let message = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
        throw SyncCodec.error(failMessage: message.trimmingCharacters(in: .whitespacesAndNewlines), path: path)
    }

    private func withSync<T>(_ body: (SyncSession) async throws -> T) async throws -> T {
        let sync = try await SyncSession(opener: opener)
        do {
            let value = try await body(sync)
            await sync.close()
            return value
        } catch {
            await sync.close()
            throw error
        }
    }

    private static func statEntry(_ path: RemotePath, _ sync: SyncSession) async throws -> RemoteEntry {
        let stat = try await sync.stat(path)
        try require(stat, path)
        return entry(path, stat)
    }

    private static func require(_ stat: SyncStat, _ path: RemotePath) throws {
        if stat.error != 0 { throw SyncCodec.error(errno: stat.error, path: path) }
        if stat.mode == 0 { throw DeviceError.notFound(path) }
    }

    static func entry(_ path: RemotePath, _ stat: SyncStat) -> RemoteEntry {
        RemoteEntry(path: path, kind: stat.kind,
                    size: stat.kind == .directory ? 0 : stat.size,
                    mtime: Date(timeIntervalSince1970: TimeInterval(stat.mtime)),
                    mode: stat.mode & 0o7777)
    }
}
