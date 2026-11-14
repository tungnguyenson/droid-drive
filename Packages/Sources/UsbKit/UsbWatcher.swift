import Foundation
import IOKit
import os

private let log = Logger(subsystem: "com.droiddrive.usb", category: "watcher")

/// A plug or unplug seen by `UsbWatcher`.
public enum UsbEvent: Hashable, Sendable {
    /// A device appeared, or its interfaces changed (the user picked "File transfer" on
    /// the phone, which re-enumerates it). Consumers treat it as an upsert.
    case attached(UsbDeviceInfo)
    /// A device that was reported as attached went away.
    case detached(registryID: UInt64)
}

/// Watches USB plug and unplug with IOKit matching notifications (spec §5.3, plan P1-03).
/// Read-only: it never opens a device.
public enum UsbWatcher {
    /// Phones DroidDrive can talk to, and phones plugged in "Charging only" mode.
    public static let defaultFilter: @Sendable (UsbDeviceInfo) -> Bool = {
        $0.hasAndroidInterface || $0.looksLikeChargingPhone
    }

    /// Delay before re-reading a device after an interface appears: a phone publishes
    /// its interfaces one by one, and one event per burst is enough.
    static let settleDelay: DispatchTimeInterval = .milliseconds(250)

    /// Starts with an `.attached` event for every matching device already plugged in,
    /// then reports changes until the stream is dropped.
    public static func events(filter: @escaping @Sendable (UsbDeviceInfo) -> Bool = defaultFilter) -> AsyncStream<UsbEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(filter: filter, continuation: continuation)
            watcher.start()
            continuation.onTermination = { _ in watcher.stop() }
        }
    }
}

/// IOKit notification state. Every field is touched only on `queue`.
private final class Watcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "droiddrive.usb.watcher")
    private let filter: @Sendable (UsbDeviceInfo) -> Bool
    private let continuation: AsyncStream<UsbEvent>.Continuation
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var reported: Set<UInt64> = []
    private var pending: Set<UInt64> = []
    private var selfReference: Unmanaged<Watcher>?

    init(filter: @escaping @Sendable (UsbDeviceInfo) -> Bool, continuation: AsyncStream<UsbEvent>.Continuation) {
        self.filter = filter
        self.continuation = continuation
    }

    func start() {
        queue.sync {
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                log.error("IONotificationPortCreate failed")
                continuation.finish()
                return
            }
            self.port = port
            IONotificationPortSetDispatchQueue(port, queue)
            let refcon = Unmanaged.passRetained(self)
            selfReference = refcon
            let context = refcon.toOpaque()

            let deviceAdded: IOServiceMatchingCallback = { refcon, iterator in
                Unmanaged<Watcher>.fromOpaque(refcon!).takeUnretainedValue().devicesAdded(iterator)
            }
            let interfaceAdded: IOServiceMatchingCallback = { refcon, iterator in
                Unmanaged<Watcher>.fromOpaque(refcon!).takeUnretainedValue().interfacesAdded(iterator)
            }
            let deviceRemoved: IOServiceMatchingCallback = { refcon, iterator in
                Unmanaged<Watcher>.fromOpaque(refcon!).takeUnretainedValue().devicesRemoved(iterator)
            }
            register(kIOFirstMatchNotification, UsbRegistry.deviceClass, deviceAdded, context, port)
            register(kIOFirstMatchNotification, UsbRegistry.interfaceClass, interfaceAdded, context, port)
            register(kIOTerminatedNotification, UsbRegistry.deviceClass, deviceRemoved, context, port)
        }
    }

    func stop() {
        queue.async { [self] in
            iterators.forEach { IOObjectRelease($0) }
            iterators = []
            if let port { IONotificationPortDestroy(port) }
            port = nil
            selfReference?.release()
            selfReference = nil
        }
    }

    private func register(_ type: String, _ className: String, _ callback: IOServiceMatchingCallback,
                          _ context: UnsafeMutableRawPointer, _ port: IONotificationPortRef) {
        var iterator: io_iterator_t = 0
        let status = IOServiceAddMatchingNotification(port, type, IOServiceMatching(className), callback, context, &iterator)
        guard status == KERN_SUCCESS else {
            log.error("IOServiceAddMatchingNotification(\(type, privacy: .public), \(className, privacy: .public)) failed: \(status)")
            return
        }
        iterators.append(iterator)
        // Draining the iterator delivers what is already attached and arms the notification.
        callback(context, iterator)
    }

    // MARK: Callbacks (on `queue`)

    private func devicesAdded(_ iterator: io_iterator_t) {
        UsbRegistry.forEach(iterator) { service in
            schedule(UsbRegistry.registryID(service))
        }
    }

    private func interfacesAdded(_ iterator: io_iterator_t) {
        UsbRegistry.forEach(iterator) { service in
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return }
            schedule(UsbRegistry.registryID(parent))
            IOObjectRelease(parent)
        }
    }

    private func devicesRemoved(_ iterator: io_iterator_t) {
        UsbRegistry.forEach(iterator) { service in
            let id = UsbRegistry.registryID(service)
            pending.remove(id)
            if reported.remove(id) != nil {
                continuation.yield(.detached(registryID: id))
            }
        }
    }

    /// Re-reads the device once its interfaces have settled.
    private func schedule(_ registryID: UInt64) {
        guard pending.insert(registryID).inserted else { return }
        queue.asyncAfter(deadline: .now() + UsbWatcher.settleDelay) { [self] in
            guard pending.remove(registryID) != nil, port != nil else { return }
            guard let info = UsbRegistry.device(registryID: registryID) else { return }
            if filter(info) {
                reported.insert(registryID)
                continuation.yield(.attached(info))
            } else if reported.remove(registryID) != nil {
                // It lost its Android interfaces (switched back to "Charging only").
                continuation.yield(.detached(registryID: registryID))
            }
        }
    }
}
