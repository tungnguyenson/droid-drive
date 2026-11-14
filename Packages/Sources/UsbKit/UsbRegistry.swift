import Foundation
import IOKit

/// Read-only views of the IORegistry's USB tree (plan P1-03). Nothing here opens a
/// device or sends anything on the bus: it only reads properties macOS already
/// published, so it is safe to call for every device, keyboards included.
public enum UsbRegistry {
    static let deviceClass = "IOUSBHostDevice"
    static let interfaceClass = "IOUSBHostInterface"

    /// Every USB device currently attached, with its interfaces.
    public static func devices() -> [UsbDeviceInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(deviceClass), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [UsbDeviceInfo] = []
        forEach(iterator) { service in
            if let info = deviceInfo(service) { result.append(info) }
        }
        return result
    }

    /// The device with this registry id, if still attached.
    public static func device(registryID: UInt64) -> UsbDeviceInfo? {
        withService(registryID) { deviceInfo($0) }
    }

    /// The interface with this registry id, if still attached.
    public static func interface(registryID: UInt64) -> UsbInterfaceInfo? {
        withService(registryID) { interfaceInfo($0) }
    }

    /// Who holds the interface: `UsbExclusiveOwner`, else the creator of a user client
    /// attached below it. Our own process is not reported.
    public static func holder(ofInterface registryID: UInt64) -> UsbHolder? {
        withService(registryID) { service in
            if let owner = interfaceInfo(service)?.holder, !owner.isCurrentProcess { return owner }
            return userClientCreators(below: service).first { !$0.isCurrentProcess }
        }
    }

    // MARK: Building snapshots

    static func deviceInfo(_ service: io_service_t) -> UsbDeviceInfo? {
        guard IOObjectConformsTo(service, deviceClass) != 0, let props = properties(service) else { return nil }
        var interfaces: [UsbInterfaceInfo] = []
        var children: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS {
            forEach(children) { child in
                if let info = interfaceInfo(child) { interfaces.append(info) }
            }
            IOObjectRelease(children)
        }
        return UsbDeviceInfo(registryID: registryID(service), properties: props, interfaces: interfaces)
    }

    static func interfaceInfo(_ service: io_service_t) -> UsbInterfaceInfo? {
        guard IOObjectConformsTo(service, interfaceClass) != 0, let props = properties(service) else { return nil }
        return UsbInterfaceInfo(registryID: registryID(service), properties: props)
    }

    /// The parent `IOUSBHostDevice` of an interface.
    static func parentDevice(of service: io_service_t) -> UsbDeviceInfo? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return deviceInfo(parent)
    }

    static func userClientCreators(below service: io_service_t) -> [UsbHolder] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var holders: [UsbHolder] = []
        forEach(iterator) { entry in
            let key = kIOUserClientCreatorKey as CFString
            if let value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               let holder = UsbHolder(ownerString: value) {
                holders.append(holder)
            }
        }
        return holders
    }

    // MARK: IOKit helpers

    static func registryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    static func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var dict: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = dict?.takeRetainedValue() as? [String: Any] else { return nil }
        return props
    }

    /// Calls `body` with each object of `iterator`, releasing it afterwards.
    static func forEach(_ iterator: io_iterator_t, _ body: (io_object_t) -> Void) {
        while case let object = IOIteratorNext(iterator), object != 0 {
            body(object)
            IOObjectRelease(object)
        }
    }

    /// Looks a service up by registry id; `body` must not keep it.
    static func withService<T>(_ registryID: UInt64, _ body: (io_service_t) -> T?) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return body(service)
    }
}
