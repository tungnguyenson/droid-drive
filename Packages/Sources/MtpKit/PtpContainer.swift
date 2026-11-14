import DroidCore
import Foundation

/// The 12-byte header every PTP-over-USB container starts with (PIMA 15740 USB still
/// image class, spec §5.3): length, type, code, transaction id, all little-endian.
public struct PtpContainerHeader: Hashable, Sendable {
    public enum Kind: UInt16, Sendable {
        case command = 1, data = 2, response = 3, event = 4
    }

    public static let size = 12
    /// A data container longer than 4 GB carries this length; the data then ends at a
    /// short USB packet instead.
    public static let unknownLength: UInt32 = 0xFFFF_FFFF

    public let length: UInt32
    public let kind: Kind
    public let code: UInt16
    public let transactionID: UInt32

    public init(length: UInt32, kind: Kind, code: UInt16, transactionID: UInt32) {
        self.length = length
        self.kind = kind
        self.code = code
        self.transactionID = transactionID
    }

    public var encoded: Data {
        var writer = PtpWriter()
        writer.u32(length)
        writer.u16(kind.rawValue)
        writer.u16(code)
        writer.u32(transactionID)
        return writer.data
    }

    public static func decode(_ bytes: [UInt8]) throws(DeviceError) -> PtpContainerHeader {
        var reader = PtpReader(bytes)
        guard let length = try? reader.u32(), let rawKind = try? reader.u16(),
              let code = try? reader.u16(), let transactionID = try? reader.u32() else {
            throw .protocolError("MTP container header is truncated")
        }
        guard let kind = Kind(rawValue: rawKind) else {
            throw .protocolError("Unknown MTP container type \(rawKind)")
        }
        guard length >= UInt32(size) else {
            throw .protocolError("MTP container length \(length) is shorter than its header")
        }
        return PtpContainerHeader(length: length, kind: kind, code: code, transactionID: transactionID)
    }

    /// Header for a data container carrying `payloadLength` bytes.
    public static func data(code: UInt16, transactionID: UInt32, payloadLength: UInt64) -> PtpContainerHeader {
        let total = UInt64(size) + payloadLength
        return PtpContainerHeader(length: total >= UInt64(unknownLength) ? unknownLength : UInt32(total),
                                  kind: .data, code: code, transactionID: transactionID)
    }
}

/// A command, response or event: a header plus up to five UInt32 parameters.
public struct PtpParameterContainer: Hashable, Sendable {
    public let kind: PtpContainerHeader.Kind
    public let code: UInt16
    public let transactionID: UInt32
    public let parameters: [UInt32]

    public init(kind: PtpContainerHeader.Kind, code: UInt16, transactionID: UInt32, parameters: [UInt32] = []) {
        precondition(parameters.count <= 5, "PTP containers carry at most five parameters")
        self.kind = kind
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
    }

    public var encoded: Data {
        let header = PtpContainerHeader(length: UInt32(PtpContainerHeader.size + 4 * parameters.count),
                                        kind: kind, code: code, transactionID: transactionID)
        var writer = PtpWriter()
        parameters.forEach { writer.u32($0) }
        return header.encoded + writer.data
    }

    /// Decodes a whole container. Extra bytes past the last whole parameter are ignored,
    /// and fewer than five parameters is normal (devices send only what they use).
    public static func decode(_ data: Data) throws(DeviceError) -> PtpParameterContainer {
        let bytes = [UInt8](data)
        let header = try PtpContainerHeader.decode(bytes)
        guard header.kind != .data else { throw .protocolError("Expected a parameter container, got data") }
        let end = min(Int(header.length), bytes.count)
        var reader = PtpReader(Array(bytes[PtpContainerHeader.size..<max(end, PtpContainerHeader.size)]))
        var parameters: [UInt32] = []
        while parameters.count < 5, let value = try? reader.u32() { parameters.append(value) }
        return PtpParameterContainer(kind: header.kind, code: header.code, transactionID: header.transactionID,
                                     parameters: parameters)
    }
}

/// The device's answer to one operation.
public struct PtpResponse: Hashable, Sendable {
    public let code: PtpResponseCode
    public let parameters: [UInt32]

    public init(code: PtpResponseCode, parameters: [UInt32] = []) {
        self.code = code
        self.parameters = parameters
    }

    public func parameter(_ index: Int) -> UInt32? {
        index < parameters.count ? parameters[index] : nil
    }
}

/// An event from the interrupt endpoint.
public struct PtpEvent: Hashable, Sendable {
    public let code: PtpEventCode
    public let transactionID: UInt32
    public let parameters: [UInt32]

    public init(code: PtpEventCode, transactionID: UInt32 = 0, parameters: [UInt32] = []) {
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
    }

    public init(_ container: PtpParameterContainer) throws(DeviceError) {
        guard container.kind == .event else { throw .protocolError("Expected an event container") }
        self.init(code: PtpEventCode(rawValue: container.code), transactionID: container.transactionID,
                  parameters: container.parameters)
    }

    public var encoded: Data {
        PtpParameterContainer(kind: .event, code: code.rawValue, transactionID: transactionID, parameters: parameters).encoded
    }
}

/// A failed operation: the device answered with something other than OK.
public struct MtpResponseError: Error, Hashable, Sendable, CustomStringConvertible {
    public let operation: PtpOperation
    public let code: PtpResponseCode

    public init(operation: PtpOperation, code: PtpResponseCode) {
        self.operation = operation
        self.code = code
    }

    public var description: String { "MTP \(operation) failed: \(code)" }
}
