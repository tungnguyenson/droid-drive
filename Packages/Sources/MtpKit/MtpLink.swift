import DroidCore
import Foundation
import os
import UsbKit

private let log = Logger(subsystem: "com.droiddrive.mtp", category: "link")

/// The data source of an outgoing data phase failed (the Mac file could not be read):
/// the device is still waiting for bytes, so the transaction must be cancelled.
struct MtpDataSourceFailure: Error {
    let underlying: Error
}

/// A data sink failed (the Mac file could not be written). The data phase was still read
/// to its end, so the session is in step.
struct MtpDataSinkFailure: Error {
    let underlying: Error
}

/// Supplies the bytes of an outgoing data phase, at most `maxLength` per call; nil at end.
public typealias PtpDataSource = @Sendable (_ maxLength: Int) async throws -> Data?
/// Receives the bytes of an incoming data phase as they arrive.
public typealias PtpDataSink = @Sendable (Data) throws -> Void

/// PTP containers over the bulk pipes of one MTP interface (PIMA 15740 USB transport).
/// Only `MtpSession` uses it, one transaction at a time.
///
/// USB rules this layer keeps, because breaking them hangs or corrupts the session:
/// - an OUT data phase split over several transfers sends whole packets in every transfer
///   but the last, since a short packet tells the device the container has ended;
/// - a container that ends on a packet boundary is followed by a zero-length packet;
/// - IN data is read as a byte stream split by container lengths, so a stray ZLP or a
///   device that forgets one cannot desynchronise it. Only a data container longer than
///   4 GB (length 0xFFFFFFFF) relies on transfer boundaries: it ends at a short transfer.
actor MtpLink {
    static let transferSize = 1 << 20

    private let bulkIn: any UsbPipe
    private let bulkOut: any UsbPipe
    private let control: (any UsbControlChannel)?
    private let timeout: Duration
    private var inbound = Data()
    private var inboundOffset = 0
    /// Whether the last IN transfer ended with a short packet.
    private var lastTransferShort = true

    init(bulkIn: any UsbPipe, bulkOut: any UsbPipe, control: (any UsbControlChannel)?, timeout: Duration) {
        self.bulkIn = bulkIn
        self.bulkOut = bulkOut
        self.control = control
        self.timeout = timeout
    }

    // MARK: Sending

    func sendCommand(_ code: UInt16, transactionID: UInt32, parameters: [UInt32]) async throws {
        let container = PtpParameterContainer(kind: .command, code: code, transactionID: transactionID, parameters: parameters)
        try await write(container.encoded)
    }

    /// Sends a data container of exactly `length` payload bytes pulled from `source`.
    func sendData(_ code: UInt16, transactionID: UInt32, length: UInt64, source: PtpDataSource) async throws {
        let mps = bulkOut.maxPacketSize
        let header = PtpContainerHeader.data(code: code, transactionID: transactionID, payloadLength: length)
        var pending = header.encoded
        var sent: UInt64 = 0
        while sent < length {
            try Task.checkCancellation()
            let want = Int(min(UInt64(Self.transferSize), length - sent))
            let next: Data?
            do {
                next = try await source(want)
            } catch {
                throw MtpDataSourceFailure(underlying: error)
            }
            guard let chunk = next, !chunk.isEmpty else {
                throw MtpDataSourceFailure(underlying: DeviceError.protocolError("The file ended \(length - sent) bytes early"))
            }
            let used = chunk.count > want ? chunk.prefix(want) : chunk
            pending.append(used)
            sent += UInt64(used.count)
            if pending.count >= Self.transferSize {
                // Whole packets only, so the device does not see the container end here.
                let whole = pending.count - pending.count % mps
                try await write(pending.prefix(whole))
                pending = Data(pending.dropFirst(whole))
            }
        }
        if !pending.isEmpty { try await write(pending) }
        if (UInt64(PtpContainerHeader.size) + length) % UInt64(mps) == 0 {
            try await write(Data())
        }
    }

    private func write(_ data: Data) async throws {
        do {
            try await bulkOut.write(data, timeout: timeout)
        } catch let error as UsbError {
            throw Self.map(error)
        }
    }

    /// A transfer aborted because its task was cancelled is a cancellation, not a lost device.
    static func map(_ error: UsbError) -> Error {
        if error == .aborted && Task.isCancelled { return CancellationError() }
        return error.deviceError
    }

    // MARK: Receiving

    /// Reads one container. A data container's payload goes to `sink` (or is discarded);
    /// `expectedDataLength` sizes a >4 GB data phase when the caller knows the file size.
    func receive(sink: PtpDataSink?, expectedDataLength: UInt64? = nil) async throws -> Received {
        let header = try PtpContainerHeader.decode([UInt8](try await take(PtpContainerHeader.size)))
        switch header.kind {
        case .data:
            if header.length == PtpContainerHeader.unknownLength {
                try await forwardUntilShortTransfer(limit: expectedDataLength, sink: sink)
            } else {
                try await forward(UInt64(header.length) - UInt64(PtpContainerHeader.size), sink: sink)
            }
            return .data(code: header.code, transactionID: header.transactionID)
        case .response, .event, .command:
            let body = try await take(Int(header.length) - PtpContainerHeader.size)
            let container = try PtpParameterContainer.decode(header.encoded + body)
            return .parameters(container)
        }
    }

    enum Received {
        case data(code: UInt16, transactionID: UInt32)
        case parameters(PtpParameterContainer)
    }

    private var available: Int { inbound.count - inboundOffset }

    /// Reads one more IN transfer into the buffer.
    private func fill() async throws {
        let data: Data
        do {
            data = try await bulkIn.read(maxLength: Self.transferSize, timeout: timeout)
        } catch let error as UsbError {
            throw Self.map(error)
        }
        lastTransferShort = data.count % bulkIn.maxPacketSize != 0 || data.isEmpty
        if inboundOffset == inbound.count {
            inbound = data
        } else {
            inbound = inbound.subdata(in: (inbound.startIndex + inboundOffset)..<inbound.endIndex) + data
        }
        inboundOffset = 0
    }

    private func take(_ count: Int) async throws -> Data {
        while available < count { try await fill() }
        let start = inbound.startIndex + inboundOffset
        inboundOffset += count
        return inbound.subdata(in: start..<start + count)
    }

    private func forward(_ count: UInt64, sink: PtpDataSink?) async throws {
        var left = count
        while left > 0 {
            if available == 0 { try await fill() }
            let n = Int(min(UInt64(available), left))
            let start = inbound.startIndex + inboundOffset
            inboundOffset += n
            left -= UInt64(n)
            if let sink, n > 0 { try sink(inbound.subdata(in: start..<start + n)) }
        }
    }

    /// A >4 GB data phase: everything up to the end of the first short transfer.
    private func forwardUntilShortTransfer(limit: UInt64?, sink: PtpDataSink?) async throws {
        if let limit {
            try await forward(limit, sink: sink)
            return
        }
        while true {
            if available > 0 {
                let rest = inbound.subdata(in: (inbound.startIndex + inboundOffset)..<inbound.endIndex)
                inboundOffset = inbound.count
                try sink?(rest)
            }
            // The transfer that carried the header, or the one just read, ended short.
            if lastTransferShort { return }
            try await fill()
        }
    }

    // MARK: Cancelling

    /// Asks the device to abandon `transactionID` (USB still image class "Cancel Request",
    /// bRequest 0x64), then waits until it reports ready (Get Device Status, 0x67).
    /// Returns false when there is no control channel or the device does not recover.
    func cancel(transactionID: UInt32) async -> Bool {
        guard let control else { return false }
        var payload = PtpWriter()
        payload.u16(PtpEventCode.cancelTransaction.rawValue)
        payload.u32(transactionID)
        do {
            try await control.classRequestOut(0x64, value: 0, data: payload.data, timeout: .seconds(2))
            for _ in 0..<20 {
                let status = try await control.classRequestIn(0x67, value: 0, length: 20, timeout: .seconds(2))
                var reader = PtpReader(status)
                _ = try? reader.u16()
                let code = (try? reader.u16()) ?? PtpResponseCode.ok.rawValue
                if code != PtpResponseCode.deviceBusy.rawValue { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            log.error("MTP cancel failed: \(String(describing: error), privacy: .public)")
            return false
        }
        inbound = Data()
        inboundOffset = 0
        // Drop whatever the device had already queued for the abandoned transaction.
        for _ in 0..<64 {
            guard let stale = try? await bulkIn.read(maxLength: Self.transferSize, timeout: .milliseconds(100)) else { break }
            if !stale.isEmpty { log.notice("Dropped \(stale.count) stale bytes after a cancel") }
        }
        return true
    }
}
