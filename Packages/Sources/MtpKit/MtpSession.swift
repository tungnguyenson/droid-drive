import DroidCore
import Foundation
import os
import UsbKit

private let log = Logger(subsystem: "com.droiddrive.mtp", category: "session")

/// An open MTP session on one interface (plan P2-02): GetDeviceInfo + OpenSession, then
/// one operation at a time (MTP has no concurrency, spec §5.2), with device events
/// delivered on `events`.
public actor MtpSession {
    public nonisolated let deviceInfo: PtpDeviceInfo
    /// Events from the interrupt endpoint (P2-06). Finishes when the device goes away.
    public nonisolated let events: AsyncStream<PtpEvent>

    private let link: MtpLink
    private let channels: UsbInterfaceChannels
    private let lock = AsyncLock()
    private var nextTransactionID: UInt32 = 1
    private var eventTask: Task<Void, Never>?
    /// Set when a transfer failed half-way: the byte stream may be out of step, so every
    /// later call fails with `disconnected` and the owner reopens the session.
    private var broken = false
    private var closed = false

    private init(link: MtpLink, channels: UsbInterfaceChannels, deviceInfo: PtpDeviceInfo) {
        self.link = link
        self.channels = channels
        self.deviceInfo = deviceInfo
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1024))
    }

    private let eventContinuation: AsyncStream<PtpEvent>.Continuation

    /// Reads DeviceInfo and opens a session. `timeout` bounds each USB transfer; Android
    /// can take seconds to build the property list of a large folder.
    public static func open(channels: UsbInterfaceChannels, sessionID: UInt32 = 1,
                            timeout: Duration = .seconds(60)) async throws -> MtpSession {
        let link = MtpLink(bulkIn: channels.bulkIn, bulkOut: channels.bulkOut, control: channels.control, timeout: timeout)
        // GetDeviceInfo and OpenSession run outside a session with transaction id 0.
        let infoData = DataCollector()
        let infoResponse = try await transact(link, .getDeviceInfo, [], transactionID: 0, sink: infoData.sink)
        guard infoResponse.code == .ok else { throw MtpResponseError(operation: .getDeviceInfo, code: infoResponse.code) }
        let info = try PtpDeviceInfo.decode(infoData.data)
        let openResponse = try await transact(link, .openSession, [sessionID], transactionID: 0)
        guard openResponse.code == .ok || openResponse.code == .sessionAlreadyOpen else {
            throw MtpResponseError(operation: .openSession, code: openResponse.code)
        }
        let session = MtpSession(link: link, channels: channels, deviceInfo: info)
        await session.startEvents()
        log.info("MTP session open: \(info.manufacturer, privacy: .public) \(info.model, privacy: .public), \(info.operations.count) operations")
        return session
    }

    public nonisolated func supports(_ operation: PtpOperation) -> Bool { deviceInfo.supports(operation) }

    // MARK: Transactions

    /// Runs one operation and returns the device's response, whatever its code.
    /// `dataOut` sends a data phase; `sink` receives an incoming one.
    public func run(_ operation: PtpOperation, _ parameters: [UInt32] = [],
                    dataOut: (length: UInt64, source: PtpDataSource)? = nil,
                    sink: PtpDataSink? = nil, expectedDataLength: UInt64? = nil) async throws -> PtpResponse {
        await lock.lock()
        do {
            let response = try await runLocked(operation, parameters, dataOut: dataOut, sink: sink,
                                               expectedDataLength: expectedDataLength)
            await lock.unlock()
            return response
        } catch {
            await lock.unlock()
            throw error
        }
    }

    /// Like `run`, but throws `MtpResponseError` unless the device said OK.
    @discardableResult
    public func call(_ operation: PtpOperation, _ parameters: [UInt32] = [],
                     dataOut: (length: UInt64, source: PtpDataSource)? = nil,
                     sink: PtpDataSink? = nil, expectedDataLength: UInt64? = nil) async throws -> PtpResponse {
        let response = try await run(operation, parameters, dataOut: dataOut, sink: sink, expectedDataLength: expectedDataLength)
        guard response.code == .ok else { throw MtpResponseError(operation: operation, code: response.code) }
        return response
    }

    /// Runs an operation with an incoming data phase and returns the data.
    public func fetch(_ operation: PtpOperation, _ parameters: [UInt32] = []) async throws -> Data {
        let collector = DataCollector()
        try await call(operation, parameters, sink: collector.sink)
        return collector.data
    }

    /// Runs operations back to back with no other operation in between (SendObjectInfo
    /// must be followed by its SendObject). `body` gets a runner that must not be
    /// used after it returns.
    public func exclusive<T: Sendable>(_ body: @Sendable (Runner) async throws -> T) async throws -> T {
        await lock.lock()
        do {
            let value = try await body(Runner(session: self))
            await lock.unlock()
            return value
        } catch {
            await lock.unlock()
            throw error
        }
    }

    /// Runs operations while `exclusive` holds the lock.
    public struct Runner: Sendable {
        let session: MtpSession

        public func call(_ operation: PtpOperation, _ parameters: [UInt32] = [],
                         dataOut: (length: UInt64, source: PtpDataSource)? = nil,
                         sink: PtpDataSink? = nil) async throws -> PtpResponse {
            let response = try await session.runLocked(operation, parameters, dataOut: dataOut, sink: sink, expectedDataLength: nil)
            guard response.code == .ok else { throw MtpResponseError(operation: operation, code: response.code) }
            return response
        }
    }

    private func runLocked(_ operation: PtpOperation, _ parameters: [UInt32],
                           dataOut: (length: UInt64, source: PtpDataSource)?,
                           sink: PtpDataSink?, expectedDataLength: UInt64?) async throws -> PtpResponse {
        guard !broken, !closed else { throw DeviceError.disconnected }
        let transactionID = nextTransactionID
        nextTransactionID = nextTransactionID >= 0xFFFF_FFFE ? 1 : nextTransactionID + 1
        do {
            return try await Self.transact(link, operation, parameters, transactionID: transactionID, dataOut: dataOut,
                                           sink: sink, expectedDataLength: expectedDataLength)
        } catch let failure as MtpDataSinkFailure {
            throw failure.underlying
        } catch let failure as MtpDataSourceFailure {
            // The device still expects data: ask it to drop the transaction.
            await cancelTransaction(transactionID)
            throw failure.underlying
        } catch is CancellationError {
            // Cancelled in the middle of a data phase: ask the device to drop it.
            await cancelTransaction(transactionID)
            throw CancellationError()
        } catch let error as MtpResponseError {
            throw error
        } catch let error as DeviceError {
            if case .invalidName = error { throw error }
            markBroken("\(error)")
            throw error
        } catch {
            markBroken("\(error)")
            throw error
        }
    }

    /// Runs the PTP cancel in a task of its own: the calling task is usually cancelled,
    /// and its transfers would abort at once.
    private func cancelTransaction(_ transactionID: UInt32) async {
        let link = self.link
        let recovered = await Task { await link.cancel(transactionID: transactionID) }.value
        if !recovered { markBroken("cancel failed") }
    }

    private func markBroken(_ reason: String) {
        if !broken { log.error("MTP session out of step, closing: \(reason, privacy: .public)") }
        broken = true
    }

    /// One transaction on the link: command, optional data phase, response.
    private static func transact(_ link: MtpLink, _ operation: PtpOperation, _ parameters: [UInt32],
                                 transactionID: UInt32, dataOut: (length: UInt64, source: PtpDataSource)? = nil,
                                 sink: PtpDataSink? = nil, expectedDataLength: UInt64? = nil) async throws -> PtpResponse {
        try await link.sendCommand(operation.rawValue, transactionID: transactionID, parameters: parameters)
        if let dataOut {
            try await link.sendData(operation.rawValue, transactionID: transactionID, length: dataOut.length, source: dataOut.source)
        }
        // A sink error (disk full on the Mac) must not leave the device's data unread.
        let guarded = sink.map { SinkGuard($0) }
        while true {
            switch try await link.receive(sink: guarded?.sink, expectedDataLength: expectedDataLength) {
            case .data:
                continue
            case .parameters(let container) where container.kind == .response:
                if container.transactionID != transactionID && transactionID != 0 && container.transactionID < transactionID {
                    log.notice("Skipping stale MTP response for transaction \(container.transactionID)")
                    continue
                }
                if let failure = guarded?.failure { throw MtpDataSinkFailure(underlying: failure) }
                return PtpResponse(code: PtpResponseCode(rawValue: container.code), parameters: container.parameters)
            case .parameters:
                continue // events belong on the interrupt pipe; ignore strays
            }
        }
    }

    // MARK: Events

    private func startEvents() {
        guard let pipe = channels.interruptIn else {
            eventContinuation.finish()
            return
        }
        let continuation = eventContinuation
        eventTask = Task.detached {
            let mps = pipe.maxPacketSize
            let length = ((64 + mps - 1) / mps) * mps
            while !Task.isCancelled {
                do {
                    let data = try await pipe.read(maxLength: length, timeout: nil)
                    guard data.count >= PtpContainerHeader.size,
                          let container = try? PtpParameterContainer.decode(data),
                          let event = try? PtpEvent(container) else { continue }
                    continuation.yield(event)
                } catch {
                    break
                }
            }
            continuation.finish()
        }
    }

    // MARK: Closing

    /// Closes the session and releases the interface.
    public func close() async {
        guard !closed else { return }
        if !broken {
            _ = try? await run(.closeSession)
        }
        closed = true
        eventTask?.cancel()
        await channels.interruptIn?.abort()
        await channels.close()
        eventContinuation.finish()
    }
}

/// Collects a data phase into memory (datasets are small; file data uses its own sink).
final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    var data: Data { lock.withLock { buffer } }

    var sink: PtpDataSink { { [self] chunk in lock.withLock { buffer.append(chunk) } } }
}

/// Keeps the first error a sink throws and swallows the rest of the data phase, so the
/// response can still be read and the session stays in step.
private final class SinkGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let base: PtpDataSink
    private var _failure: Error?

    init(_ base: @escaping PtpDataSink) { self.base = base }

    var failure: Error? { lock.withLock { _failure } }

    var sink: PtpDataSink {
        { [self] chunk in
            guard failure == nil else { return }
            do { try base(chunk) } catch { lock.withLock { _failure = error } }
        }
    }
}
