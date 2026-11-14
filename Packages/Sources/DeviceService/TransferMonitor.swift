import DroidCore
import Foundation

/// A transfer in progress, as the UI shows it.
public struct ActiveTransfer: Sendable, Equatable, Identifiable {
    public let id: String
    public let phoneId: String
    public let path: String
    public let direction: TransferDirection
    public let started: Date
    public var completed: Int64
    public var total: Int64
}

public enum TransferEvent: Sendable, Equatable {
    case started(ActiveTransfer)
    case finished(TransferRecord)
}

/// Tracks running transfers (menu bar spinner, FR-19 "confirm before cancelling") and
/// writes each finished one to the `TransferLog` (FR-17).
public actor TransferMonitor {
    public let log: TransferLog
    private let clock: @Sendable () -> Date
    private var active: [String: ActiveTransfer] = [:]
    private var cancellers: [String: @Sendable () -> Void] = [:]
    private var subscribers: [UUID: AsyncStream<TransferEvent>.Continuation] = [:]

    public init(log: TransferLog, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.log = log
        self.clock = clock
    }

    public var activeTransfers: [ActiveTransfer] {
        active.values.sorted { $0.started < $1.started }
    }

    public func activeCount(phoneId: String) -> Int {
        active.values.filter { $0.phoneId == phoneId }.count
    }

    /// Every start and finish from now on.
    public func events() -> AsyncStream<TransferEvent> {
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    /// Runs `body` as transfer `id`, logs the outcome, and returns the byte count
    /// `body` reports. `cancel` stops it (used by `cancel(id:)`).
    public func run(id: String, phoneId: String, deviceName: String, path: String, direction: TransferDirection,
                    cancel: @escaping @Sendable () -> Void,
                    _ body: @Sendable () async throws -> UInt64) async throws -> UInt64 {
        let start = clock()
        begin(ActiveTransfer(id: id, phoneId: phoneId, path: path, direction: direction,
                             started: start, completed: 0, total: 0), cancel: cancel)
        let outcome: Result<UInt64, Error>
        do {
            outcome = .success(try await body())
        } catch {
            outcome = .failure(error)
        }
        let bytes: UInt64
        let result: TransferResult
        switch outcome {
        case .success(let size):
            bytes = size
            result = .succeeded
        case .failure(let error):
            bytes = UInt64(max(0, active[id]?.completed ?? 0))
            result = error is CancellationError ? .cancelled : .failed(Self.describe(error))
        }
        await finish(TransferRecord(started: start, phoneId: phoneId, deviceName: deviceName, path: path,
                              direction: direction, bytes: bytes,
                              duration: max(0, clock().timeIntervalSince(start)), result: result), id: id)
        return try outcome.get()
    }

    public func progress(id: String, completed: Int64, total: Int64) {
        active[id]?.completed = completed
        active[id]?.total = total
    }

    public func cancel(id: String) {
        cancellers[id]?()
    }

    /// Cancels every transfer of a phone (FR-19, after the user confirmed).
    public func cancelAll(phoneId: String) {
        for transfer in active.values where transfer.phoneId == phoneId {
            cancellers[transfer.id]?()
        }
    }

    private func begin(_ transfer: ActiveTransfer, cancel: @escaping @Sendable () -> Void) {
        active[transfer.id] = transfer
        cancellers[transfer.id] = cancel
        broadcast(.started(transfer))
    }

    private func finish(_ record: TransferRecord, id: String) async {
        active[id] = nil
        cancellers[id] = nil
        broadcast(.finished(record))
        await log.append(record)
    }

    private func broadcast(_ event: TransferEvent) {
        subscribers.values.forEach { $0.yield(event) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    static func describe(_ error: Error) -> String {
        if let device = error as? DeviceError { return device.userMessage }
        return (error as NSError).localizedDescription
    }
}
