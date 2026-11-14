import Foundation
import IOKit
@preconcurrency import IOUSBHost
import os

private let log = Logger(subsystem: "com.droiddrive.usb", category: "interface")

/// `kIOMessageServiceIsTerminated` (`iokit_common_msg(0x010)`), a macro Swift does not import.
private let serviceIsTerminated: UInt32 = 0xE000_0010

/// Opens an Android ADB or MTP interface with `IOUSBHostInterface` (spec §5.3, §5.4).
///
/// Safety: it refuses any interface that `AndroidInterfaceKind.classify` does not
/// recognise, so a keyboard, hub or camera on the same Mac can never be opened or seized
/// through this API, whatever registry id a caller passes.
public enum UsbInterfaceOpener {
    /// Opens the interface exclusively and returns its pipes.
    ///
    /// - Parameter seize: asks the current owner to let go
    ///   (`IOUSBHostObjectInitOptionsDeviceSeize`). Only for an explicit user "Try again";
    ///   by default a busy interface fails with `UsbError.exclusiveAccess(holder)`.
    public static func open(registryID: UInt64, seize: Bool = false) throws(UsbError) -> UsbInterfaceChannels {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard service != 0 else { throw .notFound }
        defer { IOObjectRelease(service) }
        guard let info = UsbRegistry.interfaceInfo(service) else { throw .notFound }
        guard let kind = info.kind else {
            throw .notAndroidInterface(String(format: "class %02x/%02x/%02x %@", info.interfaceClass,
                                              info.interfaceSubclass, info.interfaceProtocol, info.name ?? ""))
        }

        let queue = DispatchQueue(label: "droiddrive.usb.\(kind.rawValue).\(registryID)")
        let state = InterfaceState()
        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: seize ? .deviceSeize : [],
                                               queue: queue) { _, messageType, _ in
                if messageType == serviceIsTerminated { state.terminated() }
            }
        } catch {
            let status = Int32(truncatingIfNeeded: (error as NSError).code)
            if status == kIOReturnExclusiveAccess {
                let holder = UsbRegistry.holder(ofInterface: registryID)
                log.notice("Interface \(registryID) is held by \(holder?.processName ?? "unknown", privacy: .public)")
                throw .exclusiveAccess(holder)
            }
            log.error("Opening interface \(registryID) failed: \(String(describing: error), privacy: .public)")
            throw UsbError.from(ioReturn: status)
        }

        let endpoints: UsbEndpointSet
        do {
            endpoints = try endpointSet(of: interface)
        } catch {
            interface.destroy()
            throw error
        }
        do {
            let bulkIn = try HostPipe(interface, endpoints.bulkIn)
            let bulkOut = try HostPipe(interface, endpoints.bulkOut)
            let events = try endpoints.interruptIn.map { try HostPipe(interface, $0) }
            let pipes = [bulkIn, bulkOut] + (events.map { [$0] } ?? [])
            state.onTerminate = { pipes.forEach { $0.abortNow() } }
            let control = HostControl(interface: interface, interfaceNumber: UInt16(info.number))
            return UsbInterfaceChannels(bulkIn: bulkIn, bulkOut: bulkOut, interruptIn: events, control: control) {
                pipes.forEach { $0.abortNow() }
                interface.destroy()
            }
        } catch {
            interface.destroy()
            throw UsbError.from(ioReturn: Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }

    /// Endpoints of the interface's current alternate setting, from the configuration
    /// descriptor IOUSBHost already read.
    static func endpointSet(of interface: IOUSBHostInterface) throws(UsbError) -> UsbEndpointSet {
        let config = interface.configurationDescriptor
        let total = Int(config.pointee.wTotalLength)
        let bytes = config.withMemoryRebound(to: UInt8.self, capacity: total) { Array(UnsafeBufferPointer(start: $0, count: total)) }
        let current = interface.interfaceDescriptor.pointee
        guard let parsed = try? UsbDescriptors.interfaces(inConfiguration: bytes),
              let match = parsed.first(where: { $0.number == current.bInterfaceNumber && $0.alternateSetting == current.bAlternateSetting }),
              let set = UsbEndpointSet(match.endpoints) else {
            throw .notAndroidInterface("interface \(current.bInterfaceNumber) has no bulk IN/OUT pair")
        }
        return set
    }
}

/// Termination flag shared with IOUSBHost's interest handler (runs on its queue).
private final class InterfaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var _onTerminate: (@Sendable () -> Void)?
    private var isTerminated = false

    var onTerminate: (@Sendable () -> Void)? {
        get { lock.withLock { _onTerminate } }
        set {
            let fireNow = lock.withLock { () -> Bool in
                _onTerminate = newValue
                return isTerminated
            }
            if fireNow { newValue?() }
        }
    }

    func terminated() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            isTerminated = true
            return _onTerminate
        }
        action?()
    }
}

/// `UsbPipe` over an `IOUSBHostPipe`. IOUSBHost objects may be used from any thread;
/// `@unchecked` covers their missing Sendable annotations. One transfer at a time per
/// direction is the callers' job (UsbPacketLink's send lock, MtpSession's lock).
final class HostPipe: UsbPipe, @unchecked Sendable {
    let maxPacketSize: Int
    private let pipe: IOUSBHostPipe
    private let interface: IOUSBHostInterface
    private let lock = NSLock()
    private var spare: NSMutableData?

    init(_ interface: IOUSBHostInterface, _ endpoint: UsbEndpoint) throws {
        self.interface = interface
        self.pipe = try interface.copyPipe(withAddress: Int(endpoint.address))
        self.maxPacketSize = max(endpoint.maxPacketSize, 8)
    }

    func read(maxLength: Int, timeout: Duration?) async throws -> Data {
        let buffer = try takeBuffer(maxLength)
        defer { returnBuffer(buffer) }
        let count = try await transfer(buffer, timeout: timeout)
        return Data(bytes: buffer.bytes, count: count)
    }

    func write(_ data: Data, timeout: Duration?) async throws {
        guard !data.isEmpty else {
            _ = try await transfer(nil, timeout: timeout) // zero-length packet
            return
        }
        let buffer = try takeBuffer(data.count)
        defer { returnBuffer(buffer) }
        data.withUnsafeBytes { buffer.mutableBytes.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        _ = try await transfer(buffer, timeout: timeout)
    }

    func abort() async { abortNow() }

    func abortNow() {
        try? pipe.__abort(with: .asynchronous)
    }

    func clearStall() async throws {
        do { try pipe.clearStall() } catch { throw UsbError.from(ioReturn: Int32(truncatingIfNeeded: (error as NSError).code)) }
    }

    private func transfer(_ buffer: NSMutableData?, timeout: Duration?) async throws -> Int {
        let pipe = self.pipe
        let box = UncheckedBox(buffer)
        let (status, count): (IOReturn, Int) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try pipe.enqueueIORequest(with: box.value, completionTimeout: timeout?.timeInterval ?? 0) { status, count in
                        continuation.resume(returning: (status, count))
                    }
                } catch {
                    continuation.resume(throwing: UsbError.from(ioReturn: Int32(truncatingIfNeeded: (error as NSError).code)))
                }
            }
        } onCancel: {
            try? pipe.__abort(with: .asynchronous)
        }
        switch status {
        case kIOReturnSuccess, kIOReturnUnderrun:
            return count
        case UsbError.pipeStalled:
            try? pipe.clearStall()
            throw UsbError.stalled
        default:
            throw UsbError.from(ioReturn: status)
        }
    }

    /// IOUSBHost wants buffers from `ioData(withCapacity:)` (wired for DMA); allocating
    /// one per 1 MB transfer is wasteful, so the last one is kept for reuse.
    private func takeBuffer(_ length: Int) throws -> NSMutableData {
        let reused = lock.withLock { () -> NSMutableData? in
            defer { spare = nil }
            return spare
        }
        if let reused, reused.length >= length || reused.length == 0 {
            reused.length = length
            return reused
        }
        let fresh = try interface.ioData(withCapacity: max(length, maxPacketSize))
        fresh.length = length
        return fresh
    }

    private func returnBuffer(_ buffer: NSMutableData) {
        lock.withLock { if spare == nil { spare = buffer } }
    }
}

/// Class requests to one interface over the default control pipe.
final class HostControl: UsbControlChannel, @unchecked Sendable {
    private let interface: IOUSBHostInterface
    private let interfaceNumber: UInt16

    init(interface: IOUSBHostInterface, interfaceNumber: UInt16) {
        self.interface = interface
        self.interfaceNumber = interfaceNumber
    }

    /// bmRequestType: class request, interface recipient (USB 2.0 §9.3.1).
    static let classInterfaceOut: UInt8 = 0x21
    static let classInterfaceIn: UInt8 = 0xA1

    func classRequestOut(_ request: UInt8, value: UInt16, data: Data, timeout: Duration) async throws {
        let buffer = NSMutableData(data: data)
        _ = try send(IOUSBDeviceRequest(bmRequestType: Self.classInterfaceOut, bRequest: request, wValue: value,
                                        wIndex: interfaceNumber, wLength: UInt16(data.count)),
                     buffer.length > 0 ? buffer : nil, timeout)
    }

    func classRequestIn(_ request: UInt8, value: UInt16, length: Int, timeout: Duration) async throws -> Data {
        let buffer = NSMutableData(length: length)!
        let count = try send(IOUSBDeviceRequest(bmRequestType: Self.classInterfaceIn, bRequest: request, wValue: value,
                                                wIndex: interfaceNumber, wLength: UInt16(length)), buffer, timeout)
        return Data(bytes: buffer.bytes, count: count)
    }

    private func send(_ request: IOUSBDeviceRequest, _ data: NSMutableData?, _ timeout: Duration) throws -> Int {
        var transferred = 0
        do {
            try interface.__send(request, data: data, bytesTransferred: &transferred,
                                              completionTimeout: timeout.timeInterval)
        } catch {
            throw UsbError.from(ioReturn: Int32(truncatingIfNeeded: (error as NSError).code))
        }
        return transferred
    }
}

/// Carries a non-Sendable IOUSBHost buffer into a `@Sendable` closure that only passes
/// it straight back to IOUSBHost.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
