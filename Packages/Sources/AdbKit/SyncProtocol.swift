import DroidCore
import Foundation

/// File metadata as the sync service reports it (`STAT`/`STA2`/`DENT`/`DNT2`).
public struct SyncStat: Equatable, Sendable {
    public let mode: UInt32
    public let size: UInt64
    public let mtime: Int64
    /// errno from STA2/DNT2; 0 on success. `STAT` reports a missing file as mode 0.
    public let error: UInt32

    public var exists: Bool { error == 0 && mode != 0 }

    public var kind: EntryKind {
        switch mode & 0o170000 {
        case 0o040000: .directory
        case 0o100000: .file
        case 0o120000: .symlink
        default: .other
        }
    }
}

/// Encoders and decoders for the sync protocol (AOSP `SYNC.TXT`), kept free of I/O so
/// they can be tested with captured bytes.
enum SyncCodec {
    static let list = fourCC("LIST"), list2 = fourCC("LIS2")
    static let dent = fourCC("DENT"), dent2 = fourCC("DNT2")
    static let stat = fourCC("STAT"), stat2 = fourCC("STA2"), lstat2 = fourCC("LST2")
    static let send = fourCC("SEND"), recv = fourCC("RECV")
    static let data = fourCC("DATA"), done = fourCC("DONE")
    static let okay = fourCC("OKAY"), fail = fourCC("FAIL"), quit = fourCC("QUIT")

    /// Largest DATA chunk the device accepts (SYNC_DATA_MAX).
    static let maxChunk = 64 * 1024
    /// Longest path the sync service accepts.
    static let maxPath = 1024

    /// `id` + length + path (LIST, LIS2, STAT, STA2, RECV, SEND).
    static func request(_ id: UInt32, _ path: String) throws(DeviceError) -> Data {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPath else { throw .invalidName(path, reason: "Path is longer than \(maxPath) bytes") }
        var out = Data(capacity: 8 + bytes.count)
        out.appendLE(id)
        out.appendLE(UInt32(bytes.count))
        out.append(contentsOf: bytes)
        return out
    }

    static func header(_ id: UInt32, _ value: UInt32) -> Data {
        var out = Data(capacity: 8)
        out.appendLE(id)
        out.appendLE(value)
        return out
    }

    /// Body of a DENT after its id: mode, size, mtime, namelen (16 bytes).
    static let dentBodySize = 16
    /// Body of a DNT2 after its id (72 bytes), before the name.
    static let dent2BodySize = 72
    /// Body of a STA2 response after its id (68 bytes).
    static let stat2BodySize = 68

    static func decodeDent(_ body: [UInt8]) throws -> (SyncStat, nameLength: Int) {
        var r = ByteReader(body)
        let mode: UInt32 = try r.read()
        let size: UInt32 = try r.read()
        let mtime: UInt32 = try r.read()
        let nameLength: UInt32 = try r.read()
        return (SyncStat(mode: mode, size: UInt64(size), mtime: Int64(mtime), error: 0), Int(nameLength))
    }

    static func decodeDent2(_ body: [UInt8]) throws -> (SyncStat, nameLength: Int) {
        var r = ByteReader(body)
        let stat = try decodeStat2Fields(&r)
        let nameLength: UInt32 = try r.read()
        return (stat, Int(nameLength))
    }

    static func decodeStat2(_ body: [UInt8]) throws -> SyncStat {
        var r = ByteReader(body)
        return try decodeStat2Fields(&r)
    }

    /// error, dev, ino, mode, nlink, uid, gid, size, atime, mtime, ctime.
    private static func decodeStat2Fields(_ r: inout ByteReader) throws -> SyncStat {
        let error: UInt32 = try r.read()
        _ = try r.read(UInt64.self) // dev
        _ = try r.read(UInt64.self) // ino
        let mode: UInt32 = try r.read()
        _ = try r.read(UInt32.self) // nlink
        _ = try r.read(UInt32.self) // uid
        _ = try r.read(UInt32.self) // gid
        let size: UInt64 = try r.read()
        _ = try r.read(Int64.self) // atime
        let mtime: Int64 = try r.read()
        _ = try r.read(Int64.self) // ctime
        return SyncStat(mode: mode, size: size, mtime: mtime, error: error)
    }

    static func decodeStat(_ body: [UInt8]) throws -> SyncStat {
        var r = ByteReader(body)
        let mode: UInt32 = try r.read()
        let size: UInt32 = try r.read()
        let mtime: UInt32 = try r.read()
        return SyncStat(mode: mode, size: UInt64(size), mtime: Int64(mtime), error: 0)
    }

    /// Maps the errno in STA2/DNT2 to the shared error type.
    static func error(errno: UInt32, path: RemotePath) -> DeviceError {
        switch errno {
        case 2, 20: .notFound(path)          // ENOENT, ENOTDIR
        case 1, 13: .permissionDenied(path)  // EPERM, EACCES
        case 17: .exists(path)               // EEXIST
        case 28: .noSpace(needed: 0, available: 0)
        default: .protocolError("errno \(errno) at \(path)")
        }
    }

    /// Maps a FAIL message (strerror text from the device) to the shared error type.
    static func error(failMessage: String, path: RemotePath) -> DeviceError {
        let text = failMessage.lowercased()
        if text.contains("no such file") || text.contains("not a directory") { return .notFound(path) }
        if text.contains("permission denied") || text.contains("operation not permitted") || text.contains("read-only") {
            return .permissionDenied(path)
        }
        if text.contains("no space") { return .noSpace(needed: 0, available: 0) }
        if text.contains("file exists") || text.contains("is a directory") { return .exists(path) }
        return .protocolError(failMessage)
    }
}

/// One `sync:` session. Not thread-safe; open one per task (adb does the same).
final class SyncSession {
    private let stream: any AdbByteStream
    private let reader: StreamReader
    private let useV2: Bool

    init(opener: any AdbServiceOpener) async throws {
        stream = try await opener.open("sync:")
        reader = StreamReader(stream)
        useV2 = opener.features.contains("ls_v2") && opener.features.contains("stat_v2")
    }

    func close() async {
        try? await stream.write(SyncCodec.header(SyncCodec.quit, 0))
        await stream.close()
    }

    func stat(_ path: RemotePath) async throws -> SyncStat {
        if useV2 {
            try await stream.write(try SyncCodec.request(SyncCodec.lstat2, path.string))
            let id = try await readId()
            guard id == SyncCodec.lstat2 else { throw unexpected(id) }
            return try SyncCodec.decodeStat2(try await reader.readExactly(SyncCodec.stat2BodySize))
        }
        try await stream.write(try SyncCodec.request(SyncCodec.stat, path.string))
        let id = try await readId()
        guard id == SyncCodec.stat else { throw unexpected(id) }
        return try SyncCodec.decodeStat(try await reader.readExactly(12))
    }

    /// Lists a directory, calling `onEntry` for each child except "." and "..".
    func list(_ dir: RemotePath, onEntry: (String, SyncStat) throws -> Void) async throws {
        try await stream.write(try SyncCodec.request(useV2 ? SyncCodec.list2 : SyncCodec.list, dir.string))
        while true {
            let id = try await readId()
            let (stat, nameLength): (SyncStat, Int)
            switch id {
            case SyncCodec.dent2:
                (stat, nameLength) = try SyncCodec.decodeDent2(try await reader.readExactly(SyncCodec.dent2BodySize))
            case SyncCodec.dent:
                (stat, nameLength) = try SyncCodec.decodeDent(try await reader.readExactly(SyncCodec.dentBodySize))
            case SyncCodec.done:
                // DONE carries a zeroed body the same size as a DENT/DNT2 plus name length.
                _ = try await reader.readExactly(useV2 ? SyncCodec.dent2BodySize : SyncCodec.dentBodySize)
                return
            default:
                throw unexpected(id)
            }
            guard nameLength <= 4096 else { throw DeviceError.protocolError("File name is unexpectedly long") }
            let name = String(decoding: try await reader.readExactly(nameLength), as: UTF8.self)
            if name != "." && name != ".." { try onEntry(name, stat) }
        }
    }

    /// Streams the whole file into `sink`.
    func pull(_ path: RemotePath, sink: (Data) throws -> Void) async throws {
        try await stream.write(try SyncCodec.request(SyncCodec.recv, path.string))
        while true {
            let header = try await reader.readExactly(8)
            var r = ByteReader(header)
            let id: UInt32 = try r.read()
            let length: UInt32 = try r.read()
            switch id {
            case SyncCodec.data:
                guard length <= UInt32(SyncCodec.maxChunk) * 4 else { throw DeviceError.protocolError("DATA chunk too large") }
                try await reader.forward(Int(length), to: sink)
            case SyncCodec.done:
                return
            case SyncCodec.fail:
                throw SyncCodec.error(failMessage: try await failText(length), path: path)
            default:
                throw unexpected(id)
            }
        }
    }

    /// Sends a file. `source` returns the next chunk, or nil at end. Packs several
    /// 64 KB DATA chunks into each write so a WRTE carries up to the link's max payload.
    func push(_ path: RemotePath, mode: UInt32, mtime: Int64,
              source: () throws -> Data?) async throws {
        try await stream.write(try SyncCodec.request(SyncCodec.send, "\(path.string),\(mode)"))
        var pending = Data()
        let flushThreshold = 256 * 1024
        while let chunk = try source(), !chunk.isEmpty {
            var offset = chunk.startIndex
            while offset < chunk.endIndex {
                let end = min(offset + SyncCodec.maxChunk, chunk.endIndex)
                pending.append(SyncCodec.header(SyncCodec.data, UInt32(end - offset)))
                pending.append(chunk[offset..<end])
                offset = end
            }
            if pending.count >= flushThreshold {
                try await stream.write(pending)
                pending = Data()
            }
        }
        pending.append(SyncCodec.header(SyncCodec.done, UInt32(truncatingIfNeeded: mtime)))
        try await stream.write(pending)

        let header = try await reader.readExactly(8)
        var r = ByteReader(header)
        let id: UInt32 = try r.read()
        let length: UInt32 = try r.read()
        switch id {
        case SyncCodec.okay:
            return
        case SyncCodec.fail:
            throw SyncCodec.error(failMessage: try await failText(length), path: path)
        default:
            throw unexpected(id)
        }
    }

    private func readId() async throws -> UInt32 {
        var r = ByteReader(try await reader.readExactly(4))
        return try r.read()
    }

    private func failText(_ length: UInt32) async throws -> String {
        guard length <= 4096 else { throw DeviceError.protocolError("Error message too long") }
        return String(decoding: try await reader.readExactly(Int(length)), as: UTF8.self)
    }

    private func unexpected(_ id: UInt32) -> DeviceError {
        .protocolError("Unknown sync response: \(fourCCString(id))")
    }
}
