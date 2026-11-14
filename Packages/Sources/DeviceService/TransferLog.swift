import Foundation
import os

private let log = Logger(subsystem: "com.droiddrive.deviceservice", category: "transfer-log")

public enum TransferDirection: String, Codable, Sendable, CaseIterable {
    /// Phone → Mac.
    case download
    /// Mac → phone.
    case upload
}

public enum TransferResult: Codable, Sendable, Equatable {
    case succeeded
    case failed(String)
    case cancelled

    public var kind: Kind {
        switch self {
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case succeeded, failed, cancelled
    }
}

/// One upload or download (spec FR-17).
public struct TransferRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let started: Date
    public let phoneId: String
    public let deviceName: String
    /// Path on the phone.
    public let path: String
    public let direction: TransferDirection
    /// Bytes moved (the file size when it succeeded).
    public let bytes: UInt64
    public let duration: TimeInterval
    public let result: TransferResult

    public init(id: UUID = UUID(), started: Date, phoneId: String, deviceName: String, path: String,
                direction: TransferDirection, bytes: UInt64, duration: TimeInterval, result: TransferResult) {
        self.id = id
        self.started = started
        self.phoneId = phoneId
        self.deviceName = deviceName
        self.path = path
        self.direction = direction
        self.bytes = bytes
        self.duration = duration
        self.result = result
    }

    public var fileName: String { (path as NSString).lastPathComponent }

    /// Average bytes per second; nil when too short to measure.
    public var bytesPerSecond: Double? {
        duration >= 0.001 ? Double(bytes) / duration : nil
    }
}

public struct TransferFilter: Equatable, Sendable {
    public var phoneId: String?
    public var result: TransferResult.Kind?
    public var direction: TransferDirection?
    /// Case-insensitive match on the path.
    public var text: String

    public init(phoneId: String? = nil, result: TransferResult.Kind? = nil,
                direction: TransferDirection? = nil, text: String = "") {
        self.phoneId = phoneId
        self.result = result
        self.direction = direction
        self.text = text
    }

    public func matches(_ record: TransferRecord) -> Bool {
        if let phoneId, record.phoneId != phoneId { return false }
        if let result, record.result.kind != result { return false }
        if let direction, record.direction != direction { return false }
        let needle = text.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, record.path.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        return true
    }
}

/// Transfer history kept for 7 days (spec §6 "Transfer log"), one JSON object per line
/// in the app group container. Lines are appended with O_APPEND so a second writer
/// (the extension, should it ever log) cannot interleave inside a line.
public actor TransferLog {
    public static let retention: TimeInterval = 7 * 24 * 3600

    private let url: URL?
    private var records: [TransferRecord] = []
    private var loaded = false

    /// `url` nil keeps the log in memory only (tests, unsigned builds).
    public init(url: URL?) {
        self.url = url
    }

    /// Newest first.
    public func entries(matching filter: TransferFilter = TransferFilter(), now: Date = Date()) -> [TransferRecord] {
        loadIfNeeded(now: now)
        return records.reversed().filter(filter.matches)
    }

    public func append(_ record: TransferRecord) {
        loadIfNeeded(now: Date())
        records.append(record)
        guard let url else { return }
        var line = (try? JSONEncoder.log.encode(record)) ?? Data()
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            log.error("cannot open transfer log: errno \(errno, privacy: .public)")
            return
        }
        defer { close(fd) }
        let written = line.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        if written != line.count {
            log.error("short write to transfer log: \(written, privacy: .public) of \(line.count, privacy: .public)")
        }
    }

    /// Drops records older than the retention period, in memory and on disk.
    public func prune(now: Date = Date()) {
        loadIfNeeded(now: now)
        let cutoff = now.addingTimeInterval(-Self.retention)
        let kept = records.filter { $0.started >= cutoff }
        guard kept.count != records.count else { return }
        records = kept
        rewrite()
    }

    public func clear() {
        records = []
        loaded = true
        rewrite()
    }

    /// Re-reads the file (another process may have appended).
    public func reload(now: Date = Date()) {
        loaded = false
        loadIfNeeded(now: now)
    }

    private func loadIfNeeded(now: Date) {
        guard !loaded else { return }
        loaded = true
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let cutoff = now.addingTimeInterval(-Self.retention)
        let decoder = JSONDecoder.log
        var all: [TransferRecord] = []
        var dropped = false
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let record = try? decoder.decode(TransferRecord.self, from: Data(line)) else {
                dropped = true   // a torn or foreign line; skip it
                continue
            }
            if record.started >= cutoff { all.append(record) } else { dropped = true }
        }
        records = all.sorted { $0.started < $1.started }
        if dropped { rewrite() }
    }

    private func rewrite() {
        guard let url else { return }
        var data = Data()
        let encoder = JSONEncoder.log
        for record in records {
            if let line = try? encoder.encode(record) {
                data.append(line)
                data.append(0x0A)
            }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("cannot rewrite transfer log: \(String(describing: error), privacy: .public)")
        }
    }
}

private extension JSONEncoder {
    static var log: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

private extension JSONDecoder {
    static var log: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
