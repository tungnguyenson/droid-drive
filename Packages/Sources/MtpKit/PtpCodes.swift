import Foundation

/// PTP/MTP operation codes (PTP 1.1 §10.4, MTP 1.1 Appendix D, Android extensions in
/// AOSP `frameworks/av/media/mtp/mtp.h`). Only the ones DroidDrive uses, plus a few that
/// make `droiddrive-usb mtp-info` output readable.
public struct PtpOperation: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let getDeviceInfo = Self(rawValue: 0x1001)
    public static let openSession = Self(rawValue: 0x1002)
    public static let closeSession = Self(rawValue: 0x1003)
    public static let getStorageIDs = Self(rawValue: 0x1004)
    public static let getStorageInfo = Self(rawValue: 0x1005)
    public static let getNumObjects = Self(rawValue: 0x1006)
    public static let getObjectHandles = Self(rawValue: 0x1007)
    public static let getObjectInfo = Self(rawValue: 0x1008)
    public static let getObject = Self(rawValue: 0x1009)
    public static let getThumb = Self(rawValue: 0x100A)
    public static let deleteObject = Self(rawValue: 0x100B)
    public static let sendObjectInfo = Self(rawValue: 0x100C)
    public static let sendObject = Self(rawValue: 0x100D)
    public static let moveObject = Self(rawValue: 0x1019)
    public static let copyObject = Self(rawValue: 0x101A)
    public static let getPartialObject = Self(rawValue: 0x101B)
    public static let getObjectPropsSupported = Self(rawValue: 0x9801)
    public static let getObjectPropDesc = Self(rawValue: 0x9802)
    public static let getObjectPropValue = Self(rawValue: 0x9803)
    public static let setObjectPropValue = Self(rawValue: 0x9804)
    public static let getObjectPropList = Self(rawValue: 0x9805)
    public static let sendObjectPropList = Self(rawValue: 0x9808)
    // Android extensions.
    public static let getPartialObject64 = Self(rawValue: 0x95C1)
    public static let sendPartialObject = Self(rawValue: 0x95C2)
    public static let truncateObject = Self(rawValue: 0x95C3)
    public static let beginEditObject = Self(rawValue: 0x95C4)
    public static let endEditObject = Self(rawValue: 0x95C5)

    /// The four operations Android needs to edit a file in place (spec §5.3).
    public static let editOperations: [PtpOperation] = [.beginEditObject, .sendPartialObject, .truncateObject, .endEditObject]

    static let names: [UInt16: String] = [
        0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession", 0x1004: "GetStorageIDs",
        0x1005: "GetStorageInfo", 0x1006: "GetNumObjects", 0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo",
        0x1009: "GetObject", 0x100A: "GetThumb", 0x100B: "DeleteObject", 0x100C: "SendObjectInfo",
        0x100D: "SendObject", 0x1019: "MoveObject", 0x101A: "CopyObject", 0x101B: "GetPartialObject",
        0x9801: "GetObjectPropsSupported", 0x9802: "GetObjectPropDesc", 0x9803: "GetObjectPropValue",
        0x9804: "SetObjectPropValue", 0x9805: "GetObjectPropList", 0x9808: "SendObjectPropList",
        0x95C1: "GetPartialObject64", 0x95C2: "SendPartialObject", 0x95C3: "TruncateObject",
        0x95C4: "BeginEditObject", 0x95C5: "EndEditObject",
    ]

    public var description: String { Self.names[rawValue] ?? String(format: "0x%04X", rawValue) }
}

/// Response codes (PTP 1.1 §11, MTP 1.1 Appendix F).
public struct PtpResponseCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let ok = Self(rawValue: 0x2001)
    public static let generalError = Self(rawValue: 0x2002)
    public static let sessionNotOpen = Self(rawValue: 0x2003)
    public static let invalidTransactionID = Self(rawValue: 0x2004)
    public static let operationNotSupported = Self(rawValue: 0x2005)
    public static let parameterNotSupported = Self(rawValue: 0x2006)
    public static let incompleteTransfer = Self(rawValue: 0x2007)
    public static let invalidStorageID = Self(rawValue: 0x2008)
    public static let invalidObjectHandle = Self(rawValue: 0x2009)
    public static let invalidObjectFormatCode = Self(rawValue: 0x200B)
    public static let storeFull = Self(rawValue: 0x200C)
    public static let objectWriteProtected = Self(rawValue: 0x200D)
    public static let storeReadOnly = Self(rawValue: 0x200E)
    public static let accessDenied = Self(rawValue: 0x200F)
    public static let partialDeletion = Self(rawValue: 0x2012)
    public static let storeNotAvailable = Self(rawValue: 0x2013)
    public static let specificationByFormatUnsupported = Self(rawValue: 0x2014)
    public static let deviceBusy = Self(rawValue: 0x2019)
    public static let invalidParentObject = Self(rawValue: 0x201A)
    public static let invalidParameter = Self(rawValue: 0x201D)
    public static let sessionAlreadyOpen = Self(rawValue: 0x201E)
    public static let transactionCancelled = Self(rawValue: 0x201F)
    public static let invalidObjectPropCode = Self(rawValue: 0xA801)
    public static let invalidObjectPropValue = Self(rawValue: 0xA803)
    public static let invalidDataset = Self(rawValue: 0xA806)
    public static let specificationByGroupUnsupported = Self(rawValue: 0xA807)
    public static let specificationByDepthUnsupported = Self(rawValue: 0xA808)
    public static let objectTooLarge = Self(rawValue: 0xA809)
    public static let objectPropNotSupported = Self(rawValue: 0xA80A)

    static let names: [UInt16: String] = [
        0x2001: "OK", 0x2002: "GeneralError", 0x2003: "SessionNotOpen", 0x2004: "InvalidTransactionID",
        0x2005: "OperationNotSupported", 0x2006: "ParameterNotSupported", 0x2007: "IncompleteTransfer",
        0x2008: "InvalidStorageID", 0x2009: "InvalidObjectHandle", 0x200B: "InvalidObjectFormatCode",
        0x200C: "StoreFull", 0x200D: "ObjectWriteProtected", 0x200E: "StoreReadOnly", 0x200F: "AccessDenied",
        0x2012: "PartialDeletion", 0x2013: "StoreNotAvailable", 0x2014: "SpecificationByFormatUnsupported",
        0x2019: "DeviceBusy", 0x201A: "InvalidParentObject", 0x201D: "InvalidParameter",
        0x201E: "SessionAlreadyOpen", 0x201F: "TransactionCancelled", 0xA801: "InvalidObjectPropCode",
        0xA803: "InvalidObjectPropValue", 0xA806: "InvalidDataset", 0xA807: "SpecificationByGroupUnsupported",
        0xA808: "SpecificationByDepthUnsupported", 0xA809: "ObjectTooLarge", 0xA80A: "ObjectPropNotSupported",
    ]

    public var description: String { Self.names[rawValue] ?? String(format: "0x%04X", rawValue) }
}

/// Event codes (PTP 1.1 §12, MTP 1.1 Appendix G).
public struct PtpEventCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let cancelTransaction = Self(rawValue: 0x4001)
    public static let objectAdded = Self(rawValue: 0x4002)
    public static let objectRemoved = Self(rawValue: 0x4003)
    public static let storeAdded = Self(rawValue: 0x4004)
    public static let storeRemoved = Self(rawValue: 0x4005)
    public static let devicePropChanged = Self(rawValue: 0x4006)
    public static let objectInfoChanged = Self(rawValue: 0x4007)
    public static let deviceInfoChanged = Self(rawValue: 0x4008)
    public static let storageInfoChanged = Self(rawValue: 0x400C)
    public static let objectPropChanged = Self(rawValue: 0xC801)
}

/// Object format codes.
public enum PtpObjectFormat {
    public static let undefined: UInt16 = 0x3000
    /// A folder.
    public static let association: UInt16 = 0x3001
    /// AssociationType for a folder in ObjectInfo.
    public static let genericFolder: UInt16 = 0x0001
}

/// Object property codes (MTP 1.1 Appendix B).
public enum PtpObjectProperty {
    public static let storageID: UInt16 = 0xDC01
    public static let objectFormat: UInt16 = 0xDC02
    public static let protectionStatus: UInt16 = 0xDC03
    public static let objectSize: UInt16 = 0xDC04
    public static let objectFileName: UInt16 = 0xDC07
    public static let dateCreated: UInt16 = 0xDC08
    public static let dateModified: UInt16 = 0xDC09
    public static let parentObject: UInt16 = 0xDC0B
    public static let persistentUID: UInt16 = 0xDC41
    public static let name: UInt16 = 0xDC44
    /// "All properties" in GetObjectPropList.
    public static let all: UInt32 = 0xFFFF_FFFF
}

/// Data type codes for property values (PTP 1.1 §5.3).
public enum PtpDataType {
    public static let int8: UInt16 = 0x0001
    public static let uint8: UInt16 = 0x0002
    public static let int16: UInt16 = 0x0003
    public static let uint16: UInt16 = 0x0004
    public static let int32: UInt16 = 0x0005
    public static let uint32: UInt16 = 0x0006
    public static let int64: UInt16 = 0x0007
    public static let uint64: UInt16 = 0x0008
    public static let int128: UInt16 = 0x0009
    public static let uint128: UInt16 = 0x000A
    /// Array of the scalar type `code & 0x0FFF`.
    public static let arrayFlag: UInt16 = 0x4000
    public static let string: UInt16 = 0xFFFF
}

/// Special handle values. PTP uses different ones for "root" depending on the
/// operation, and Android follows that (AOSP `MtpServer.cpp`).
public enum PtpHandle {
    /// GetObjectHandles / SendObjectInfo parent meaning "the storage root".
    public static let root: UInt32 = 0xFFFF_FFFF
    /// ParentObject value of an object at the storage root, and MoveObject/CopyObject's root.
    public static let noParent: UInt32 = 0
    /// GetObjectHandles storage id meaning "every storage".
    public static let allStorages: UInt32 = 0xFFFF_FFFF
}
