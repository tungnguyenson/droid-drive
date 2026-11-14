import Foundation

/// An in-memory endpoint with real USB transfer semantics, for tests and fake devices
/// (the way `FakeTransport` stands in for a phone). One side writes transfers, the other
/// reads them; who is "host" and who is "device" only depends on which end calls what.
///
/// What it reproduces, because the framing code depends on it:
/// - a read ends at a short packet (a transfer whose length is not a multiple of
///   `maxPacketSize`, or a zero-length packet), or when `maxLength` bytes arrived; a
///   transfer of whole packets runs on into the next one, as on the wire;
/// - a read whose `maxLength` would split a packet fails with `overflow` (babble);
/// - a full queue blocks the writer, so a 6 GB stream never sits in memory.
public actor MemoryUsbPipe: UsbPipe {
    public nonisolated let maxPacketSize: Int
    private let capacity: Int

    private var segments: [Data] = []
    private var queuedBytes = 0
    private var closed = false
    private enum Side { case reader, writer }
    private var waiters: [UUID: (side: Side, continuation: CheckedContinuation<Void, Error>)] = [:]
    /// Lengths of transfers written, when `recordTransfers` is on (tests check ZLPs).
    public private(set) var transferLengths: [Int] = []
    private let recordTransfers: Bool

    public init(maxPacketSize: Int = 512, capacity: Int = 8 << 20, recordTransfers: Bool = false) {
        precondition(maxPacketSize > 0)
        self.maxPacketSize = maxPacketSize
        self.capacity = capacity
        self.recordTransfers = recordTransfers
    }

    // MARK: UsbPipe

    public func write(_ data: Data, timeout: Duration?) async throws {
        while !closed && queuedBytes > 0 && queuedBytes + data.count > capacity {
            try await wait(.writer, timeout: timeout)
        }
        guard !closed else { throw UsbError.disconnected }
        // A cancelled transfer never reaches the wire, even if room appeared meanwhile.
        if Task.isCancelled { throw UsbError.aborted }
        segments.append(data)
        queuedBytes += data.count
        if recordTransfers { transferLengths.append(data.count) }
        wakeAll(.reader)
    }

    public func read(maxLength: Int, timeout: Duration?) async throws -> Data {
        while true {
            guard !closed else { throw UsbError.disconnected }
            if let plan = try plan(maxLength) {
                return consume(plan)
            }
            try await wait(.reader, timeout: timeout)
        }
    }

    public func abort() {
        failAll(UsbError.aborted)
    }

    public func clearStall() {}

    /// Drops queued transfers, as aborting a real pipe drops data not yet sent.
    public func flush() {
        segments = []
        queuedBytes = 0
        wakeAll(.writer)
    }

    /// Simulates unplugging: pending and later transfers fail with `disconnected`.
    public func close() {
        closed = true
        failAll(UsbError.disconnected)
    }

    // MARK: Transfer assembly

    /// What the next read takes once a whole transfer is queued: its byte count, and
    /// whether a zero-length packet ends it (and is consumed with it). nil to wait.
    private func plan(_ maxLength: Int) throws -> (count: Int, endsWithZLP: Bool)? {
        var taken = 0
        for segment in segments {
            if taken == maxLength { return (taken, false) }
            if segment.isEmpty { return (taken, true) }
            let room = maxLength - taken
            if segment.count > room {
                // The read fills up inside this segment: only legal on a packet boundary.
                guard room % maxPacketSize == 0 else { throw UsbError.overflow }
                return (maxLength, false)
            }
            taken += segment.count
            if segment.count % maxPacketSize != 0 { return (taken, false) } // short packet
        }
        return taken == maxLength && taken > 0 ? (taken, false) : nil
    }

    private func consume(_ plan: (count: Int, endsWithZLP: Bool)) -> Data {
        var out = Data(capacity: plan.count)
        var left = plan.count
        while left > 0 {
            let first = segments.removeFirst()
            if first.count <= left {
                out.append(first)
                left -= first.count
            } else {
                out.append(first.prefix(left))
                segments.insert(Data(first.dropFirst(left)), at: 0)
                left = 0
            }
        }
        if plan.endsWithZLP { segments.removeFirst() }
        queuedBytes -= out.count
        wakeAll(.writer)
        return out
    }

    // MARK: Waiting

    private func wait(_ side: Side, timeout: Duration?) async throws {
        let id = UUID()
        let timer = timeout.map { limit in
            Task { [weak self] in
                try await Task.sleep(for: limit)
                await self?.fail(id, UsbError.timedOut)
            }
        }
        defer { timer?.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: UsbError.aborted)
                } else {
                    waiters[id] = (side, continuation)
                }
            }
        } onCancel: {
            Task { await self.fail(id, UsbError.aborted) }
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }

    private func wakeAll(_ side: Side) {
        let woken = waiters.filter { $0.value.side == side }
        woken.keys.forEach { waiters.removeValue(forKey: $0) }
        woken.values.forEach { $0.continuation.resume() }
    }

    private func failAll(_ error: Error) {
        let pending = waiters.values
        waiters = [:]
        pending.forEach { $0.continuation.resume(throwing: error) }
    }
}
