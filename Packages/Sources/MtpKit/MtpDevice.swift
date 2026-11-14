import DroidCore
import Foundation
import os
import UsbKit

private let log = Logger(subsystem: "com.droiddrive.mtp", category: "device")

/// Opening an MTP transport on a USB device (plan P2-07, P2-08).
public extension MtpTransport {
    /// Opens the MTP (or PTP) interface of `device`, starts a session, and returns a
    /// ready transport.
    ///
    /// When another process holds the interface this throws `DeviceError.busy(by:)` with
    /// the process name; `UsbRegistry.holder(ofInterface:)` and `UsbHolder.advice` give
    /// the UI the details (spec §5.7). Wrap the call in `BusyRetry.run` for the automatic
    /// retry, catching `UsbError.exclusiveAccess` through `openChannels`.
    static func open(device: UsbDeviceInfo, seize: Bool = false, timeZone: TimeZone = .current) async throws -> MtpTransport {
        guard let interface = device.mtpInterface else {
            throw DeviceError.unsupported("The phone is not in File transfer mode")
        }
        return try await open(interfaceRegistryID: interface.registryID, serial: device.serial, seize: seize, timeZone: timeZone)
    }

    static func open(interfaceRegistryID: UInt64, serial: String? = nil, seize: Bool = false,
                     timeZone: TimeZone = .current) async throws -> MtpTransport {
        let channels: UsbInterfaceChannels
        do {
            channels = try openChannels(interfaceRegistryID: interfaceRegistryID, seize: seize)
        } catch {
            throw error.deviceError
        }
        return try await open(channels: channels, serial: serial, timeZone: timeZone)
    }

    /// Like `UsbInterfaceOpener.open`, but refuses an interface that is not MTP/PTP.
    static func openChannels(interfaceRegistryID: UInt64, seize: Bool = false) throws(UsbError) -> UsbInterfaceChannels {
        guard let interface = UsbRegistry.interface(registryID: interfaceRegistryID) else { throw .notFound }
        guard interface.kind?.speaksPTP == true else {
            throw .notAndroidInterface("interface \(interface.number) is not an MTP interface")
        }
        return try UsbInterfaceOpener.open(registryID: interfaceRegistryID, seize: seize)
    }

    /// Starts a session on already-open pipes (also how tests attach a fake device).
    static func open(channels: UsbInterfaceChannels, serial: String? = nil,
                     timeZone: TimeZone = .current) async throws -> MtpTransport {
        do {
            let session = try await MtpSession.open(channels: channels)
            return MtpTransport(session: session, serial: serial, timeZone: timeZone)
        } catch {
            log.error("MTP session failed to open: \(String(describing: error), privacy: .public)")
            await channels.close()
            if let response = error as? MtpResponseError { throw deviceError(response, path: .root) }
            throw error
        }
    }
}
