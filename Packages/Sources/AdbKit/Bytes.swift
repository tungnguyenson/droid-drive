import Foundation

/// Little-endian helpers shared by the ADB packet, sync and shell codecs.
extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// Sequential little-endian reader over a byte array. Throws `truncated` instead of
/// trapping, because every byte it reads came from the device.
struct ByteReader {
    enum Failure: Error { case truncated }

    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(_ data: Data) { self.bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func read<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw Failure.truncated }
        var value: T = 0
        for index in 0..<size {
            value |= T(truncatingIfNeeded: bytes[offset + index]) << (8 * index)
        }
        offset += size
        return value
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw Failure.truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
}

/// Four-character ADB/sync identifiers ("CNXN", "LIS2"…) as little-endian UInt32.
func fourCC(_ text: StaticString) -> UInt32 {
    precondition(text.utf8CodeUnitCount == 4)
    let p = text.utf8Start
    return UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
}

func fourCCString(_ value: UInt32) -> String {
    let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    return String(decoding: bytes, as: UTF8.self)
}
