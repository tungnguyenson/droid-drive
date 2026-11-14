import Foundation

/// The interface every layer above the transports talks to (spec §5.2).
/// `AdbTransport`, later `MtpTransport`, and `FakeTransport` implement it.
public protocol DeviceTransport: Sendable {
    var info: DeviceInfo { get }

    func storages() async throws -> [StorageInfo]

    /// Lists one directory (not recursive), delivering entries in batches so the UI can
    /// show the first page before the whole directory is read.
    func list(_ dir: RemotePath) -> AsyncThrowingStream<[RemoteEntry], Error>

    func stat(_ path: RemotePath) async throws -> RemoteEntry

    /// Copies the file into `fd` from its current offset. `range` nil means the whole file.
    func read(_ path: RemotePath, to fd: FileHandle, range: Range<UInt64>?,
              progress: Progress) async throws

    /// Writes `fd` (from offset 0 to EOF) to `path`, replacing it if it exists, and sets
    /// the mtime when given and supported. Returns the entry as the device now reports it.
    func write(_ path: RemotePath, from fd: FileHandle, mtime: Date?,
               progress: Progress) async throws -> RemoteEntry

    /// Creates the directory (and missing parents). Fails with `exists` if a file is there.
    func mkdir(_ path: RemotePath) async throws -> RemoteEntry

    func delete(_ path: RemotePath, recursive: Bool) async throws

    /// Renames or moves. Fails with `exists` when `to` already exists; never overwrites.
    func rename(_ from: RemotePath, to: RemotePath) async throws -> RemoteEntry

    var changes: AsyncStream<ChangeHint> { get }
}

public extension DeviceTransport {
    /// Collects every batch of `list` into one array.
    func listAll(_ dir: RemotePath) async throws -> [RemoteEntry] {
        var all: [RemoteEntry] = []
        for try await batch in list(dir) { all.append(contentsOf: batch) }
        return all
    }
}
