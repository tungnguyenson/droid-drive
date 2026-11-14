import DroidCore
import Foundation
import IOKit

/// One USB endpoint as the protocol layers see it (plan P1-03). The real implementation
/// wraps `IOUSBHostPipe`; tests use `MemoryUsbPipe`, which keeps the same transfer
/// semantics, so ADB and MTP framing is tested without hardware.
///
/// Transfer semantics, which both ADB and MTP framing depend on:
/// - `read(maxLength:)` completes when `maxLength` bytes arrived, or when the device sent
///   a short packet (fewer than `maxPacketSize` bytes, including a zero-length packet).
///   So a read can return less than asked for, or nothing at all (a ZLP).
/// - `write` sends one transfer. If its length is not a multiple of `maxPacketSize` the
///   last packet is short and ends the transfer on the device side; `write(Data())` sends
///   a zero-length packet.
public protocol UsbPipe: Sendable {
    /// wMaxPacketSize of the endpoint: 512 for USB 2 bulk, 1024 for USB 3.
    var maxPacketSize: Int { get }

    /// One IN transfer of up to `maxLength` bytes. `timeout` nil waits forever.
    func read(maxLength: Int, timeout: Duration?) async throws -> Data

    /// One OUT transfer. Empty `data` sends a zero-length packet.
    func write(_ data: Data, timeout: Duration?) async throws

    /// Fails every pending transfer on this pipe with `UsbError.aborted`.
    func abort() async

    /// Clears a halt condition after the device stalled the endpoint.
    func clearStall() async throws
}

/// Class-specific control requests to one interface (MTP cancel / device status).
public protocol UsbControlChannel: Sendable {
    /// Host-to-device class request addressed to the interface.
    func classRequestOut(_ request: UInt8, value: UInt16, data: Data, timeout: Duration) async throws
    /// Device-to-host class request addressed to the interface; returns what the device sent.
    func classRequestIn(_ request: UInt8, value: UInt16, length: Int, timeout: Duration) async throws -> Data
}

/// The pipes of one opened interface.
public struct UsbInterfaceChannels: Sendable {
    public let bulkIn: any UsbPipe
    public let bulkOut: any UsbPipe
    /// MTP's event endpoint; ADB has none.
    public let interruptIn: (any UsbPipe)?
    public let control: (any UsbControlChannel)?
    /// Releases the interface (aborts the pipes, closes the IOUSBHost session).
    public let close: @Sendable () async -> Void

    public init(bulkIn: any UsbPipe, bulkOut: any UsbPipe, interruptIn: (any UsbPipe)? = nil,
                control: (any UsbControlChannel)? = nil, close: @escaping @Sendable () async -> Void = {}) {
        self.bulkIn = bulkIn
        self.bulkOut = bulkOut
        self.interruptIn = interruptIn
        self.control = control
        self.close = close
    }
}

/// What a USB transfer can fail with. Protocol layers map it to `DeviceError`.
public enum UsbError: Error, Equatable, Sendable {
    /// The device was unplugged, or the interface was closed.
    case disconnected
    /// The transfer was aborted (`abort()`, `close`, task cancellation).
    case aborted
    case timedOut
    /// The device halted the endpoint (USB STALL).
    case stalled
    /// The device sent more than the read asked for (USB babble).
    case overflow
    /// Another process holds the interface exclusively (`kIOReturnExclusiveAccess`).
    case exclusiveAccess(UsbHolder?)
    /// Refused to open: the interface is not an Android ADB or MTP interface.
    case notAndroidInterface(String)
    case notFound
    case failed(Int32)

    /// Maps an `IOReturn` from IOUSBHost. `kIOReturnUnderrun` (a short IN packet) is not
    /// an error: callers check it before calling this.
    public static func from(ioReturn status: Int32) -> UsbError {
        switch status {
        case kIOReturnAborted: return .aborted
        case kIOReturnTimeout: return .timedOut
        case kIOReturnOverrun: return .overflow
        case kIOReturnExclusiveAccess: return .exclusiveAccess(nil)
        case kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnNotResponding, kIOReturnOffline,
             kIOReturnNotOpen, kIOReturnNoResources:
            return .disconnected
        case Self.pipeStalled: return .stalled
        default: return .failed(status)
        }
    }

    /// `kUSBHostReturnPipeStalled`, which the Swift importer does not expose as a constant.
    static let pipeStalled = Int32(bitPattern: 0xE000_5000)

    /// The shared error the transports report (spec §5.2).
    public var deviceError: DeviceError {
        switch self {
        case .disconnected, .aborted, .notFound: return .disconnected
        case .exclusiveAccess(let holder): return .busy(by: holder?.processName)
        case .timedOut: return .protocolError("The phone did not answer in time")
        case .stalled: return .protocolError("The phone rejected a USB transfer (stall)")
        case .overflow: return .protocolError("The phone sent more data than expected")
        case .notAndroidInterface(let what): return .unsupported("Not an Android ADB or MTP interface: \(what)")
        case .failed(let status): return .protocolError(String(format: "USB error 0x%08x", UInt32(bitPattern: status)))
        }
    }
}

extension Duration {
    /// Seconds as `TimeInterval`, for IOUSBHost's completion timeouts.
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
