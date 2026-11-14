import DroidCore
import Foundation

/// GetDeviceInfo's dataset (PTP 1.1 §5.5.1). Tells which operations the phone supports,
/// which DroidDrive checks before every extension (spec §12, "manufacturers change MTP").
public struct PtpDeviceInfo: Hashable, Sendable {
    public var standardVersion: UInt16 = 100
    public var vendorExtensionID: UInt32 = 6
    public var vendorExtensionVersion: UInt16 = 100
    public var vendorExtensionDescription = "microsoft.com: 1.0; android.com: 1.0;"
    public var functionalMode: UInt16 = 0
    public var operations: [UInt16] = []
    public var events: [UInt16] = []
    public var deviceProperties: [UInt16] = []
    public var captureFormats: [UInt16] = []
    public var playbackFormats: [UInt16] = []
    public var manufacturer = ""
    public var model = ""
    public var deviceVersion = ""
    public var serialNumber = ""

    public init() {}

    public func supports(_ operation: PtpOperation) -> Bool { operations.contains(operation.rawValue) }

    public static func decode(_ data: Data) throws(DeviceError) -> PtpDeviceInfo {
        var r = PtpReader(data)
        do {
            var info = PtpDeviceInfo()
            info.standardVersion = try r.u16()
            info.vendorExtensionID = try r.u32()
            info.vendorExtensionVersion = try r.u16()
            info.vendorExtensionDescription = try r.string()
            info.functionalMode = try r.u16()
            info.operations = try r.u16Array()
            info.events = try r.u16Array()
            info.deviceProperties = try r.u16Array()
            info.captureFormats = try r.u16Array()
            info.playbackFormats = try r.u16Array()
            info.manufacturer = try r.string()
            info.model = try r.string()
            info.deviceVersion = try r.string()
            info.serialNumber = try r.string()
            return info
        } catch {
            throw .protocolError("MTP DeviceInfo is truncated")
        }
    }

    public func encoded() throws(DeviceError) -> Data {
        var w = PtpWriter()
        w.u16(standardVersion)
        w.u32(vendorExtensionID)
        w.u16(vendorExtensionVersion)
        try w.string(vendorExtensionDescription)
        w.u16(functionalMode)
        w.u16Array(operations)
        w.u16Array(events)
        w.u16Array(deviceProperties)
        w.u16Array(captureFormats)
        w.u16Array(playbackFormats)
        try w.string(manufacturer)
        try w.string(model)
        try w.string(deviceVersion)
        try w.string(serialNumber)
        return w.data
    }
}

/// GetStorageInfo's dataset (PTP 1.1 §5.5.3).
public struct PtpStorageInfo: Hashable, Sendable {
    public enum StorageType: UInt16, Sendable {
        case undefined = 0, fixedROM = 1, removableROM = 2, fixedRAM = 3, removableRAM = 4
    }

    public var storageType: UInt16
    public var filesystemType: UInt16
    public var accessCapability: UInt16
    public var maxCapacity: UInt64
    public var freeSpace: UInt64
    public var freeObjects: UInt32
    public var storageDescription: String
    public var volumeLabel: String

    public init(storageType: UInt16 = StorageType.fixedRAM.rawValue, filesystemType: UInt16 = 2,
                accessCapability: UInt16 = 0, maxCapacity: UInt64, freeSpace: UInt64,
                freeObjects: UInt32 = 0xFFFF_FFFF, storageDescription: String, volumeLabel: String = "") {
        self.storageType = storageType
        self.filesystemType = filesystemType
        self.accessCapability = accessCapability
        self.maxCapacity = maxCapacity
        self.freeSpace = freeSpace
        self.freeObjects = freeObjects
        self.storageDescription = storageDescription
        self.volumeLabel = volumeLabel
    }

    public var isRemovable: Bool {
        storageType == StorageType.removableRAM.rawValue || storageType == StorageType.removableROM.rawValue
    }

    public static func decode(_ data: Data) throws(DeviceError) -> PtpStorageInfo {
        var r = PtpReader(data)
        do {
            return PtpStorageInfo(storageType: try r.u16(), filesystemType: try r.u16(), accessCapability: try r.u16(),
                                  maxCapacity: try r.u64(), freeSpace: try r.u64(), freeObjects: try r.u32(),
                                  storageDescription: try r.string(), volumeLabel: try r.string())
        } catch {
            throw .protocolError("MTP StorageInfo is truncated")
        }
    }

    public func encoded() throws(DeviceError) -> Data {
        var w = PtpWriter()
        w.u16(storageType)
        w.u16(filesystemType)
        w.u16(accessCapability)
        w.u64(maxCapacity)
        w.u64(freeSpace)
        w.u32(freeObjects)
        try w.string(storageDescription)
        try w.string(volumeLabel)
        return w.data
    }
}

/// GetObjectInfo / SendObjectInfo's dataset (PTP 1.1 §5.5.2). Its size field is 32-bit;
/// files of 4 GB and more say 0xFFFFFFFF and the real size comes from `ObjectSize`.
public struct PtpObjectInfo: Hashable, Sendable {
    public var storageID: UInt32 = 0
    public var format: UInt16 = PtpObjectFormat.undefined
    public var protectionStatus: UInt16 = 0
    public var compressedSize: UInt32 = 0
    public var thumbFormat: UInt16 = 0
    public var thumbCompressedSize: UInt32 = 0
    public var thumbPixWidth: UInt32 = 0
    public var thumbPixHeight: UInt32 = 0
    public var imagePixWidth: UInt32 = 0
    public var imagePixHeight: UInt32 = 0
    public var imageBitDepth: UInt32 = 0
    public var parent: UInt32 = 0
    public var associationType: UInt16 = 0
    public var associationDescription: UInt32 = 0
    public var sequenceNumber: UInt32 = 0
    public var filename = ""
    public var dateCreated = ""
    public var dateModified = ""
    public var keywords = ""

    public init() {}

    public var isFolder: Bool { format == PtpObjectFormat.association }

    public static func decode(_ data: Data) throws(DeviceError) -> PtpObjectInfo {
        var r = PtpReader(data)
        do {
            var info = PtpObjectInfo()
            info.storageID = try r.u32()
            info.format = try r.u16()
            info.protectionStatus = try r.u16()
            info.compressedSize = try r.u32()
            info.thumbFormat = try r.u16()
            info.thumbCompressedSize = try r.u32()
            info.thumbPixWidth = try r.u32()
            info.thumbPixHeight = try r.u32()
            info.imagePixWidth = try r.u32()
            info.imagePixHeight = try r.u32()
            info.imageBitDepth = try r.u32()
            info.parent = try r.u32()
            info.associationType = try r.u16()
            info.associationDescription = try r.u32()
            info.sequenceNumber = try r.u32()
            info.filename = try r.string()
            // Some devices stop after the name; the dates are optional in practice.
            info.dateCreated = (try? r.string()) ?? ""
            info.dateModified = (try? r.string()) ?? ""
            info.keywords = (try? r.string()) ?? ""
            return info
        } catch {
            throw .protocolError("MTP ObjectInfo is truncated")
        }
    }

    public func encoded() throws(DeviceError) -> Data {
        var w = PtpWriter()
        w.u32(storageID)
        w.u16(format)
        w.u16(protectionStatus)
        w.u32(compressedSize)
        w.u16(thumbFormat)
        w.u32(thumbCompressedSize)
        w.u32(thumbPixWidth)
        w.u32(thumbPixHeight)
        w.u32(imagePixWidth)
        w.u32(imagePixHeight)
        w.u32(imageBitDepth)
        w.u32(parent)
        w.u16(associationType)
        w.u32(associationDescription)
        w.u32(sequenceNumber)
        try w.string(filename)
        try w.string(dateCreated)
        try w.string(dateModified)
        try w.string(keywords)
        return w.data
    }
}

/// One element of GetObjectPropList's dataset (MTP 1.1 §5.3.2.4).
public struct PtpPropListElement: Hashable, Sendable {
    public let handle: UInt32
    public let property: UInt16
    public let dataType: UInt16
    public let value: PtpValue

    public init(handle: UInt32, property: UInt16, dataType: UInt16, value: PtpValue) {
        self.handle = handle
        self.property = property
        self.dataType = dataType
        self.value = value
    }

    public static func encode(_ elements: [PtpPropListElement]) throws(DeviceError) -> Data {
        var w = PtpWriter()
        w.u32(UInt32(elements.count))
        for element in elements {
            w.u32(element.handle)
            w.u16(element.property)
            w.u16(element.dataType)
            try w.value(element.value, type: element.dataType)
        }
        return w.data
    }
}

/// Decodes an ObjectPropList while it streams in, so the first entries of a 10,000-file
/// folder can be shown before the last byte arrives (plan P2-03).
public struct PtpPropListDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var offset = 0
    private var expected: UInt32?
    public private(set) var decodedCount: UInt32 = 0

    public init() {}

    /// Number of elements the dataset announced, once its first four bytes arrived.
    public var announcedCount: UInt32? { expected }
    public var isComplete: Bool { expected.map { decodedCount >= $0 } ?? false }

    public mutating func append(_ data: Data) {
        if offset > 0 && offset >= buffer.count / 2 {
            buffer.removeFirst(offset)
            offset = 0
        }
        buffer.append(contentsOf: data)
    }

    /// Every element now complete in the buffer.
    public mutating func drain() throws -> [PtpPropListElement] {
        var out: [PtpPropListElement] = []
        var reader = PtpReader(buffer, offset: offset)
        if expected == nil {
            guard let count = try? reader.u32() else { return [] }
            expected = count
            offset = reader.offset
        }
        while decodedCount < expected! {
            do {
                let handle = try reader.u32()
                let property = try reader.u16()
                let type = try reader.u16()
                let value = try reader.value(type: type)
                out.append(PtpPropListElement(handle: handle, property: property, dataType: type, value: value))
                decodedCount += 1
                offset = reader.offset
            } catch is PtpReader.Truncated {
                break
            }
        }
        return out
    }
}
