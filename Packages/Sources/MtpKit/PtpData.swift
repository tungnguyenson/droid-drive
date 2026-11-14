import DroidCore
import Foundation

/// Builds PTP datasets: little-endian integers, PTP strings, arrays (PTP 1.1 §5.3).
public struct PtpWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ value: UInt8) { data.append(value) }
    public mutating func u16(_ value: UInt16) { appendLE(value) }
    public mutating func u32(_ value: UInt32) { appendLE(value) }
    public mutating func u64(_ value: UInt64) { appendLE(value) }

    private mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// A PTP string: one byte with the number of UTF-16 code units including the
    /// terminating NUL, then the units. The empty string is a single 0 byte.
    public mutating func string(_ value: String) throws(DeviceError) {
        let units = Array(value.utf16)
        guard !units.isEmpty else { return u8(0) }
        guard units.count < Int(UInt8.max) else {
            throw .invalidName(value, reason: "Name is longer than MTP allows (254 UTF-16 characters)")
        }
        var bytes = [UInt8](repeating: 0, count: 1 + 2 * (units.count + 1))
        bytes[0] = UInt8(units.count + 1)
        for (index, unit) in units.enumerated() {
            bytes[1 + 2 * index] = UInt8(truncatingIfNeeded: unit)
            bytes[2 + 2 * index] = UInt8(truncatingIfNeeded: unit >> 8)
        }
        data.append(contentsOf: bytes)
    }

    public mutating func u16Array(_ values: [UInt16]) {
        u32(UInt32(values.count))
        values.forEach { u16($0) }
    }

    public mutating func u32Array(_ values: [UInt32]) {
        u32(UInt32(values.count))
        values.forEach { u32($0) }
    }

    public mutating func value(_ value: PtpValue, type: UInt16) throws(DeviceError) {
        switch (type, value) {
        case (PtpDataType.string, .string(let s)): try string(s)
        case (PtpDataType.int8, .integer(let v)), (PtpDataType.uint8, .integer(let v)): u8(UInt8(truncatingIfNeeded: v))
        case (PtpDataType.int16, .integer(let v)), (PtpDataType.uint16, .integer(let v)): u16(UInt16(truncatingIfNeeded: v))
        case (PtpDataType.int32, .integer(let v)), (PtpDataType.uint32, .integer(let v)): u32(UInt32(truncatingIfNeeded: v))
        case (PtpDataType.int64, .integer(let v)), (PtpDataType.uint64, .integer(let v)): u64(v)
        case (PtpDataType.int128, .bytes(let b)) where b.count == 16, (PtpDataType.uint128, .bytes(let b)) where b.count == 16:
            data.append(b)
        default: throw .protocolError("Cannot encode \(value) as PTP type 0x\(String(type, radix: 16))")
        }
    }
}

/// A property value read from the device.
public enum PtpValue: Hashable, Sendable {
    /// Any integer up to 64 bits, as its unsigned bit pattern.
    case integer(UInt64)
    case string(String)
    /// 128-bit integers (PersistentUID) and anything else kept as raw bytes.
    case bytes(Data)
    case array([PtpValue])

    public var integer: UInt64? { if case .integer(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
}

/// Reads PTP datasets. Every byte came from the device, so running out of bytes throws
/// `Truncated` instead of trapping; streaming decoders catch it to wait for more data.
public struct PtpReader {
    public struct Truncated: Error {}

    private let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public init(_ data: Data) { self.init([UInt8](data)) }

    public var remaining: Int { bytes.count - offset }

    public mutating func u8() throws(Truncated) -> UInt8 { try integer() }
    public mutating func u16() throws(Truncated) -> UInt16 { try integer() }
    public mutating func u32() throws(Truncated) -> UInt32 { try integer() }
    public mutating func u64() throws(Truncated) -> UInt64 { try integer() }

    private mutating func integer<T: FixedWidthInteger>() throws(Truncated) -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw Truncated() }
        var value: T = 0
        for index in 0..<size {
            value |= T(truncatingIfNeeded: bytes[offset + index]) << (8 * index)
        }
        offset += size
        return value
    }

    public mutating func skip(_ count: Int) throws(Truncated) {
        guard count >= 0, remaining >= count else { throw Truncated() }
        offset += count
    }

    public mutating func raw(_ count: Int) throws(Truncated) -> Data {
        guard count >= 0, remaining >= count else { throw Truncated() }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    /// A PTP string. Keeps every code unit (an NFD name stays NFD), drops the NUL.
    public mutating func string() throws(Truncated) -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        guard remaining >= count * 2 else { throw Truncated() }
        var units = [UInt16](repeating: 0, count: count)
        for index in 0..<count {
            units[index] = UInt16(bytes[offset + 2 * index]) | UInt16(bytes[offset + 2 * index + 1]) << 8
        }
        offset += count * 2
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func u16Array() throws(Truncated) -> [UInt16] {
        let count = Int(try u32())
        guard remaining >= count * 2 else { throw Truncated() }
        return try (0..<count).map { _ throws(Truncated) in try u16() }
    }

    public mutating func u32Array() throws(Truncated) -> [UInt32] {
        let count = Int(try u32())
        guard remaining >= count * 4 else { throw Truncated() }
        return try (0..<count).map { _ throws(Truncated) in try u32() }
    }

    /// A value of PTP data type `type`. Throws `UnknownType` for a code it cannot size,
    /// since nothing after it could then be parsed.
    public mutating func value(type: UInt16) throws -> PtpValue {
        switch type {
        case PtpDataType.string: return .string(try string())
        case PtpDataType.int8, PtpDataType.uint8: return .integer(UInt64(try u8()))
        case PtpDataType.int16, PtpDataType.uint16: return .integer(UInt64(try u16()))
        case PtpDataType.int32, PtpDataType.uint32: return .integer(UInt64(try u32()))
        case PtpDataType.int64, PtpDataType.uint64: return .integer(try u64())
        case PtpDataType.int128, PtpDataType.uint128: return .bytes(try raw(16))
        case let t where t & 0xF000 == PtpDataType.arrayFlag:
            let count = Int(try u32())
            guard count <= remaining else { throw Truncated() }
            return .array(try (0..<count).map { _ in try value(type: t & 0x0FFF) })
        default:
            throw DeviceError.protocolError(String(format: "Unknown MTP data type 0x%04X", type))
        }
    }
}

/// MTP dates: "YYYYMMDDThhmmss", optionally ".s" and a "Z" or "±hhmm" suffix (PTP 1.1
/// §5.5.5). Android writes them without a suffix, in the phone's local time, and reads
/// them back the same way; DroidDrive assumes the phone and the Mac share a time zone.
public enum PtpDate {
    public static func parse(_ text: String, timeZone: TimeZone) -> Date? {
        let chars = Array(text.utf8)
        guard chars.count >= 15, chars[8] == UInt8(ascii: "T") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                guard chars[i] >= 0x30, chars[i] <= 0x39 else { return nil }
                value = value * 10 + Int(chars[i] - 0x30)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15) else { return nil }
        var zone = timeZone
        var index = 15
        if index < chars.count, chars[index] == UInt8(ascii: ".") {
            index += 1
            while index < chars.count, chars[index] >= 0x30, chars[index] <= 0x39 { index += 1 }
        }
        if index < chars.count {
            if chars[index] == UInt8(ascii: "Z") {
                zone = TimeZone(secondsFromGMT: 0)!
            } else if chars[index] == UInt8(ascii: "+") || chars[index] == UInt8(ascii: "-"), chars.count >= index + 5,
                      let hh = number(index + 1..<index + 3), let mm = number(index + 3..<index + 5) {
                let sign = chars[index] == UInt8(ascii: "-") ? -1 : 1
                zone = TimeZone(secondsFromGMT: sign * (hh * 3600 + mm * 60)) ?? timeZone
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard (1...12).contains(month), (1...31).contains(day), let date = calendar.date(from: parts) else { return nil }
        return date
    }

    /// Formats without a suffix, the way Android does, so a write reads back unchanged.
    public static func format(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
