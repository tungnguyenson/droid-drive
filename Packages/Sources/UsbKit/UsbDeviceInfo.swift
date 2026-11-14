import Foundation

/// The kinds of interface DroidDrive is allowed to open (spec §5.3, §5.4). Anything else
/// on the bus (keyboards, hubs, cameras that are not phones) is never opened.
public enum AndroidInterfaceKind: String, Sendable, Codable {
    /// Class 0xFF, subclass 0x42, protocol 0x01 (fastboot is protocol 0x03).
    case adb
    /// Android's MTP function: class 0xFF / subclass 0xFF with the interface string "MTP"
    /// (AOSP `MtpDescriptors.cpp`), or class 6/1/1 named "MTP" on older stacks.
    case mtp
    /// Class 6 (still image) / 1 / 1 without the "MTP" name: Android's "PTP" mode, or a
    /// camera. Speaks the same container protocol, with fewer operations.
    case ptp

    /// Decides from the interface descriptor and its string (`kUSBString` in IORegistry).
    public static func classify(interfaceClass: UInt8, subclass: UInt8, protocol proto: UInt8,
                                name: String?) -> AndroidInterfaceKind? {
        let namedMTP = name?.range(of: "MTP", options: .caseInsensitive) != nil
        switch (interfaceClass, subclass, proto) {
        case (0xFF, 0x42, 0x01):
            return .adb
        case (0x06, 0x01, 0x01):
            return namedMTP ? .mtp : .ptp
        case (0xFF, _, _) where namedMTP:
            return .mtp
        default:
            return nil
        }
    }

    /// MTP and PTP interfaces are both driven by MtpKit.
    public var speaksPTP: Bool { self != .adb }
}

/// One interface of a USB device as IORegistry describes it (read-only snapshot).
public struct UsbInterfaceInfo: Hashable, Sendable {
    /// IORegistry entry id: stable while the device stays plugged in.
    public let registryID: UInt64
    public let number: Int
    public let interfaceClass: UInt8
    public let interfaceSubclass: UInt8
    public let interfaceProtocol: UInt8
    public let name: String?
    /// `UsbExclusiveOwner`: who has the interface open exclusively, if anyone.
    public let exclusiveOwner: String?

    public init(registryID: UInt64, number: Int, interfaceClass: UInt8, interfaceSubclass: UInt8,
                interfaceProtocol: UInt8, name: String?, exclusiveOwner: String?) {
        self.registryID = registryID
        self.number = number
        self.interfaceClass = interfaceClass
        self.interfaceSubclass = interfaceSubclass
        self.interfaceProtocol = interfaceProtocol
        self.name = name
        self.exclusiveOwner = exclusiveOwner
    }

    /// Reads the IORegistry properties of an `IOUSBHostInterface`.
    public init(registryID: UInt64, properties: [String: Any]) {
        func byte(_ key: String) -> UInt8 { UInt8(truncatingIfNeeded: (properties[key] as? NSNumber)?.intValue ?? 0) }
        self.init(registryID: registryID,
                  number: (properties["bInterfaceNumber"] as? NSNumber)?.intValue ?? 0,
                  interfaceClass: byte("bInterfaceClass"),
                  interfaceSubclass: byte("bInterfaceSubClass"),
                  interfaceProtocol: byte("bInterfaceProtocol"),
                  name: (properties["kUSBString"] ?? properties["USB Interface Name"]) as? String,
                  exclusiveOwner: properties["UsbExclusiveOwner"] as? String)
    }

    public var kind: AndroidInterfaceKind? {
        AndroidInterfaceKind.classify(interfaceClass: interfaceClass, subclass: interfaceSubclass,
                                      protocol: interfaceProtocol, name: name)
    }

    /// The holder parsed from `exclusiveOwner`.
    public var holder: UsbHolder? { exclusiveOwner.flatMap(UsbHolder.init(ownerString:)) }
}

/// One USB device as IORegistry describes it (read-only snapshot).
public struct UsbDeviceInfo: Hashable, Sendable {
    public let registryID: UInt64
    public let vendorID: UInt16
    public let productID: UInt16
    /// The USB serial number: on Android it equals `ro.serialno`, so it keys the drive
    /// before any protocol is spoken (spec §5.4 "one phone, one identity").
    public let serial: String?
    public let manufacturer: String?
    public let product: String?
    /// Physical port; survives re-enumeration when the user switches USB mode.
    public let locationID: UInt32
    public let interfaces: [UsbInterfaceInfo]

    public init(registryID: UInt64, vendorID: UInt16, productID: UInt16, serial: String?,
                manufacturer: String?, product: String?, locationID: UInt32, interfaces: [UsbInterfaceInfo]) {
        self.registryID = registryID
        self.vendorID = vendorID
        self.productID = productID
        self.serial = serial
        self.manufacturer = manufacturer
        self.product = product
        self.locationID = locationID
        self.interfaces = interfaces
    }

    /// Reads the IORegistry properties of an `IOUSBHostDevice`.
    public init(registryID: UInt64, properties: [String: Any], interfaces: [UsbInterfaceInfo]) {
        func string(_ keys: String...) -> String? {
            keys.lazy.compactMap { properties[$0] as? String }.first { !$0.isEmpty }
        }
        func number(_ key: String) -> Int { (properties[key] as? NSNumber)?.intValue ?? 0 }
        self.init(registryID: registryID,
                  vendorID: UInt16(truncatingIfNeeded: number("idVendor")),
                  productID: UInt16(truncatingIfNeeded: number("idProduct")),
                  serial: string("kUSBSerialNumberString", "USB Serial Number"),
                  manufacturer: string("kUSBVendorString", "USB Vendor Name"),
                  product: string("kUSBProductString", "USB Product Name"),
                  locationID: UInt32(truncatingIfNeeded: number("locationID")),
                  interfaces: interfaces.sorted { $0.number < $1.number })
    }

    public var adbInterface: UsbInterfaceInfo? { interfaces.first { $0.kind == .adb } }
    /// The MTP interface, or a PTP one when the phone is in PTP mode.
    public var mtpInterface: UsbInterfaceInfo? {
        interfaces.first { $0.kind == .mtp } ?? interfaces.first { $0.kind == .ptp }
    }

    /// True when DroidDrive can talk to the device at all.
    public var hasAndroidInterface: Bool { interfaces.contains { $0.kind != nil } }

    /// A phone maker's vendor id without any usable interface: the phone is plugged in
    /// but set to "Charging only", so the UI can say "choose File transfer".
    public var looksLikeChargingPhone: Bool {
        !hasAndroidInterface && Self.phoneVendors.keys.contains(vendorID)
    }

    /// "Pixel 8", else "Google device".
    public var displayName: String {
        if let product, !product.isEmpty { return product }
        return "\(Self.phoneVendors[vendorID] ?? manufacturer ?? "USB") device"
    }

    /// USB vendor ids of Android phone makers that do not also sell common Mac peripherals
    /// (Logitech, Apple, Lenovo and the like are left out on purpose).
    public static let phoneVendors: [UInt16: String] = [
        0x18D1: "Google", 0x04E8: "Samsung", 0x2717: "Xiaomi", 0x2A70: "OnePlus",
        0x22B8: "Motorola", 0x22D9: "OPPO", 0x2D95: "vivo", 0x12D1: "Huawei",
        0x0FCE: "Sony", 0x1004: "LG", 0x0BB4: "HTC", 0x19D2: "ZTE", 0x1949: "Amazon",
        0x2A45: "Meizu", 0x2E04: "HMD", 0x2AE5: "Fairphone", 0x29A9: "Nothing",
    ]
}
