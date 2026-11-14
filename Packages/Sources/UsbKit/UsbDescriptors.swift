import Foundation

/// One endpoint of an interface, from its endpoint descriptor.
public struct UsbEndpoint: Hashable, Sendable {
    public enum TransferType: UInt8, Sendable { case control = 0, isochronous = 1, bulk = 2, interrupt = 3 }

    public let address: UInt8
    public let type: TransferType
    public let maxPacketSize: Int

    public init(address: UInt8, type: TransferType, maxPacketSize: Int) {
        self.address = address
        self.type = type
        self.maxPacketSize = maxPacketSize
    }

    /// Bit 7 of the address: device-to-host.
    public var isIn: Bool { address & 0x80 != 0 }
}

/// One alternate setting of an interface, from a configuration descriptor.
public struct UsbInterfaceDescriptor: Hashable, Sendable {
    public let number: UInt8
    public let alternateSetting: UInt8
    public let interfaceClass: UInt8
    public let interfaceSubclass: UInt8
    public let interfaceProtocol: UInt8
    public let stringIndex: UInt8
    public let endpoints: [UsbEndpoint]
}

/// The endpoints ADB and MTP need: one bulk pair, plus MTP's interrupt IN for events.
public struct UsbEndpointSet: Hashable, Sendable {
    public let bulkIn: UsbEndpoint
    public let bulkOut: UsbEndpoint
    public let interruptIn: UsbEndpoint?

    public init?(_ endpoints: [UsbEndpoint]) {
        guard let bulkIn = endpoints.first(where: { $0.type == .bulk && $0.isIn }),
              let bulkOut = endpoints.first(where: { $0.type == .bulk && !$0.isIn }) else { return nil }
        self.bulkIn = bulkIn
        self.bulkOut = bulkOut
        self.interruptIn = endpoints.first { $0.type == .interrupt && $0.isIn }
    }
}

/// Parses the bytes of a configuration descriptor (USB 2.0 §9.6.3): a chain of
/// descriptors where each interface descriptor is followed by its endpoint descriptors.
/// Every byte comes from the device, so malformed input throws instead of trapping.
public enum UsbDescriptors {
    public enum ParseError: Error, Equatable { case malformed(String) }

    static let interfaceType: UInt8 = 4
    static let endpointType: UInt8 = 5

    public static func interfaces(inConfiguration bytes: [UInt8]) throws -> [UsbInterfaceDescriptor] {
        var result: [UsbInterfaceDescriptor] = []
        var current: (header: [UInt8], endpoints: [UsbEndpoint])?
        var offset = 0
        func flush() {
            guard let open = current else { return }
            let h = open.header
            result.append(UsbInterfaceDescriptor(number: h[2], alternateSetting: h[3], interfaceClass: h[5],
                                                 interfaceSubclass: h[6], interfaceProtocol: h[7],
                                                 stringIndex: h[8], endpoints: open.endpoints))
            current = nil
        }
        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset])
            guard length >= 2, offset + length <= bytes.count else {
                throw ParseError.malformed("descriptor at offset \(offset) has length \(length)")
            }
            let descriptor = Array(bytes[offset..<offset + length])
            switch descriptor[1] {
            case interfaceType:
                guard length >= 9 else { throw ParseError.malformed("short interface descriptor") }
                flush()
                current = (descriptor, [])
            case endpointType where current != nil:
                guard length >= 7 else { throw ParseError.malformed("short endpoint descriptor") }
                let size = Int(UInt16(descriptor[4]) | UInt16(descriptor[5]) << 8) & 0x7FF
                let type = UsbEndpoint.TransferType(rawValue: descriptor[3] & 0x03)!
                current!.endpoints.append(UsbEndpoint(address: descriptor[2], type: type, maxPacketSize: size))
            default:
                break // configuration, class-specific, SuperSpeed companion…
            }
            offset += length
        }
        flush()
        return result
    }
}
