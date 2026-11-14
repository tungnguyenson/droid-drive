import DroidCore
import Foundation

/// One ADB transport packet (AOSP `protocol.txt`): a 24-byte header plus payload.
public struct AdbMessage: Equatable, Sendable {
    public enum Command: UInt32, Sendable {
        case cnxn = 0x4E58_4E43 // "CNXN"
        case auth = 0x4854_5541 // "AUTH"
        case open = 0x4E45_504F // "OPEN"
        case okay = 0x5941_4B4F // "OKAY"
        case clse = 0x4553_4C43 // "CLSE"
        case wrte = 0x4554_5257 // "WRTE"
        case stls = 0x534C_5453 // "STLS"
    }

    public static let headerSize = 24
    /// Protocol version that lets both sides skip the payload checksum.
    public static let version: UInt32 = 0x0100_0001
    public static let stlsVersion: UInt32 = 0x0100_0000
    /// Largest payload we accept or send.
    public static let maxPayload: UInt32 = 1 << 20

    public let command: Command
    public let arg0: UInt32
    public let arg1: UInt32
    public let payload: Data

    public init(_ command: Command, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.payload = payload
    }

    /// Sum of payload bytes. Peers on version ≥ 0x01000001 ignore it, older ones check it.
    public static func checksum(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    }

    /// `withChecksum` false writes 0, which peers on version ≥ 0x01000001 expect to see
    /// (adb does the same); summing every byte of a 1 GB push is not free.
    public func encodedHeader(withChecksum: Bool = true) -> Data {
        var header = Data(capacity: Self.headerSize)
        header.appendLE(command.rawValue)
        header.appendLE(arg0)
        header.appendLE(arg1)
        header.appendLE(UInt32(payload.count))
        header.appendLE(withChecksum ? Self.checksum(payload) : 0)
        header.appendLE(command.rawValue ^ 0xFFFF_FFFF)
        return header
    }

    public func encoded(withChecksum: Bool = true) -> Data { encodedHeader(withChecksum: withChecksum) + payload }

    /// Header fields before the payload has arrived.
    public struct Header: Equatable, Sendable {
        public let command: Command
        public let arg0: UInt32
        public let arg1: UInt32
        public let payloadLength: UInt32
    }

    public static func decodeHeader(_ bytes: [UInt8]) throws(DeviceError) -> Header {
        var reader = ByteReader(bytes)
        guard let raw = try? reader.read(UInt32.self),
              let arg0 = try? reader.read(UInt32.self),
              let arg1 = try? reader.read(UInt32.self),
              let length = try? reader.read(UInt32.self),
              (try? reader.read(UInt32.self)) != nil,
              let magic = try? reader.read(UInt32.self)
        else { throw .protocolError("ADB packet header is truncated") }
        guard magic == raw ^ 0xFFFF_FFFF else {
            throw .protocolError("ADB packet has a bad magic: \(String(format: "%08x", raw))")
        }
        guard let command = Command(rawValue: raw) else {
            throw .protocolError("Unknown ADB command: \(fourCCString(raw))")
        }
        guard length <= maxPayload else {
            throw .protocolError("ADB packet too large: \(length) bytes")
        }
        return Header(command: command, arg0: arg0, arg1: arg1, payloadLength: length)
    }
}

/// Incremental decoder for a byte stream of ADB packets (TCP). Feed it whatever the
/// socket returned; pull complete messages out.
public struct AdbMessageDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    public mutating func next() throws(DeviceError) -> AdbMessage? {
        guard buffer.count >= AdbMessage.headerSize else { return nil }
        let header = try AdbMessage.decodeHeader([UInt8](buffer.prefix(AdbMessage.headerSize)))
        let total = AdbMessage.headerSize + Int(header.payloadLength)
        guard buffer.count >= total else { return nil }
        let start = buffer.startIndex
        let payload = Data(buffer[(start + AdbMessage.headerSize)..<(start + total)])
        buffer = Data(buffer[(start + total)...])
        return AdbMessage(header.command, header.arg0, header.arg1, payload)
    }
}

/// What the device says about itself in its CNXN payload:
/// `device::ro.product.name=x;ro.product.model=y;ro.product.device=z;features=a,b`.
public struct DeviceBanner: Equatable, Sendable {
    public let kind: String
    public let properties: [String: String]
    public let features: Set<String>

    public init(_ payload: Data) {
        let text = String(decoding: payload, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        kind = parts.first.map(String.init) ?? ""
        var props: [String: String] = [:]
        if parts.count == 3 {
            for pair in parts[2].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { props[String(kv[0])] = String(kv[1]) }
            }
        }
        properties = props
        features = Set((props["features"] ?? "").split(separator: ",").map(String.init))
    }
}
