import DroidCore
import Foundation
import Testing
@testable import MtpKit

@Suite("PTP data types (P2-01)")
struct PtpDataTests {
    @Test("strings: count byte including NUL, UTF-16LE, empty is one zero byte")
    func strings() throws {
        var w = PtpWriter()
        try w.string("ab")
        try w.string("")
        #expect([UInt8](w.data) == [3, 0x61, 0, 0x62, 0, 0, 0, 0])
        var r = PtpReader(w.data)
        #expect(try r.string() == "ab")
        #expect(try r.string() == "")
        #expect(r.remaining == 0)
    }

    @Test("an NFD name keeps its code units through encode and decode")
    func nfdPreserved() throws {
        let nfd = "Ảnh cưới Đà Lạt.jpg".decomposedStringWithCanonicalMapping
        var w = PtpWriter()
        try w.string(nfd)
        var r = PtpReader(w.data)
        let back = try r.string()
        #expect(Array(back.utf8) == Array(nfd.utf8))
        #expect(Array(back.utf8) != Array(nfd.precomposedStringWithCanonicalMapping.utf8))
    }

    @Test("names over 254 UTF-16 units are refused, not truncated")
    func tooLong() {
        var w = PtpWriter()
        #expect(throws: DeviceError.self) { try w.string(String(repeating: "x", count: 255)) }
        #expect(throws: Never.self) { try w.string(String(repeating: "x", count: 254)) }
    }

    @Test("arrays and integers are little-endian")
    func arrays() throws {
        var w = PtpWriter()
        w.u16Array([0x1001, 0x9805])
        w.u32Array([0x0001_0001])
        w.u64(0x0102_0304_0506_0708)
        #expect([UInt8](w.data.prefix(8)) == [2, 0, 0, 0, 0x01, 0x10, 0x05, 0x98])
        var r = PtpReader(w.data)
        #expect(try r.u16Array() == [0x1001, 0x9805])
        #expect(try r.u32Array() == [0x0001_0001])
        #expect(try r.u64() == 0x0102_0304_0506_0708)
    }

    @Test("every value type round-trips", arguments: [
        (PtpDataType.int8, PtpValue.integer(0xFF)), (PtpDataType.uint8, .integer(7)),
        (PtpDataType.int16, .integer(0xFFFF)), (PtpDataType.uint16, .integer(0x3001)),
        (PtpDataType.int32, .integer(5)), (PtpDataType.uint32, .integer(0xDEAD_BEEF)),
        (PtpDataType.int64, .integer(1)), (PtpDataType.uint64, .integer(6 << 30)),
        (PtpDataType.uint128, .bytes(Data(repeating: 9, count: 16))), (PtpDataType.int128, .bytes(Data(count: 16))),
        (PtpDataType.string, .string("Đà Lạt")),
    ])
    func values(type: UInt16, value: PtpValue) throws {
        var w = PtpWriter()
        try w.value(value, type: type)
        var r = PtpReader(w.data)
        #expect(try r.value(type: type) == value)
    }

    @Test("arrays of values decode; unknown types and mismatches are errors")
    func valueErrors() throws {
        var w = PtpWriter()
        w.u32Array([1, 2])
        var r = PtpReader(w.data)
        #expect(try r.value(type: PtpDataType.arrayFlag | PtpDataType.uint32) == .array([.integer(1), .integer(2)]))
        var bad = PtpReader([0, 0])
        #expect(throws: DeviceError.self) { try bad.value(type: 0x0BAD) }
        var w2 = PtpWriter()
        #expect(throws: DeviceError.self) { try w2.value(.string("x"), type: PtpDataType.uint32) }
        #expect(throws: DeviceError.self) { try w2.value(.bytes(Data(count: 3)), type: PtpDataType.uint128) }
        #expect(PtpValue.string("a").integer == nil)
        #expect(PtpValue.integer(1).string == nil)
    }

    @Test("truncated input throws instead of trapping")
    func truncated() {
        var r = PtpReader([1, 2, 3])
        #expect(throws: PtpReader.Truncated.self) { try r.u32() }
        var s = PtpReader([5, 0x61, 0])
        #expect(throws: PtpReader.Truncated.self) { try s.string() }
        var a = PtpReader([0xFF, 0xFF, 0, 0])
        #expect(throws: PtpReader.Truncated.self) { try a.u16Array() }
        var b = PtpReader([9, 0, 0, 0])
        #expect(throws: PtpReader.Truncated.self) { try b.u32Array() }
        var c = PtpReader([1])
        #expect(throws: PtpReader.Truncated.self) { try c.skip(2) }
        #expect(throws: PtpReader.Truncated.self) { try c.raw(5) }
    }

    @Test("dates: Android's local form, UTC and offsets, fractions")
    func dates() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let hcm = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        let date = try #require(PtpDate.parse("20240102T030405", timeZone: utc))
        #expect(date == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(PtpDate.parse("20240102T100405", timeZone: hcm) == date)
        #expect(PtpDate.parse("20240102T030405Z", timeZone: hcm) == date)
        #expect(PtpDate.parse("20240102T030405.5Z", timeZone: hcm) == date)
        #expect(PtpDate.parse("20240102T100405+0700", timeZone: utc) == date)
        #expect(PtpDate.parse("20240101T230405-0400", timeZone: utc) == date)
        #expect(PtpDate.format(date, timeZone: hcm) == "20240102T100405")
        #expect(PtpDate.parse(PtpDate.format(date, timeZone: hcm), timeZone: hcm) == date)
    }

    @Test("bad dates are nil", arguments: ["", "2024", "20240102X030405", "2024010aT030405", "20241302T030405"])
    func badDates(text: String) {
        #expect(PtpDate.parse(text, timeZone: .current) == nil)
    }
}

@Suite("PTP containers (P2-01)")
struct PtpContainerTests {
    @Test("OpenSession command bytes")
    func command() throws {
        let open = PtpParameterContainer(kind: .command, code: 0x1002, transactionID: 0, parameters: [1])
        #expect([UInt8](open.encoded) == [0x10, 0, 0, 0, 1, 0, 0x02, 0x10, 0, 0, 0, 0, 1, 0, 0, 0])
        #expect(try PtpParameterContainer.decode(open.encoded) == open)
    }

    @Test("responses and events with fewer than five parameters")
    func responses() throws {
        let response = PtpParameterContainer(kind: .response, code: 0x2001, transactionID: 7, parameters: [1, 2, 3])
        #expect(try PtpParameterContainer.decode(response.encoded).parameters == [1, 2, 3])
        let event = PtpEvent(code: .objectAdded, transactionID: 0, parameters: [42])
        let decoded = try PtpEvent(try PtpParameterContainer.decode(event.encoded))
        #expect(decoded == event)
        #expect(throws: DeviceError.self) { try PtpEvent(response) }
        #expect(PtpResponse(code: .ok, parameters: [5]).parameter(0) == 5)
        #expect(PtpResponse(code: .ok).parameter(0) == nil)
    }

    @Test("data headers: exact length, or 0xFFFFFFFF past 4 GB")
    func dataHeaders() throws {
        #expect(PtpContainerHeader.data(code: 0x1009, transactionID: 3, payloadLength: 100).length == 112)
        #expect(PtpContainerHeader.data(code: 0x1009, transactionID: 3, payloadLength: 0xFFFF_FFF3).length == 0xFFFF_FFFF)
        #expect(PtpContainerHeader.data(code: 0x1009, transactionID: 3, payloadLength: 6 << 30).length == 0xFFFF_FFFF)
        let header = PtpContainerHeader.data(code: 0x1009, transactionID: 3, payloadLength: 1)
        #expect(try PtpContainerHeader.decode([UInt8](header.encoded)) == header)
    }

    @Test("malformed headers", arguments: [
        [UInt8]([1, 2, 3]),
        [12, 0, 0, 0, 9, 0, 1, 0x10, 0, 0, 0, 0],   // unknown type
        [4, 0, 0, 0, 1, 0, 1, 0x10, 0, 0, 0, 0],    // shorter than its header
    ])
    func malformed(bytes: [UInt8]) {
        #expect(throws: DeviceError.self) { try PtpContainerHeader.decode(bytes) }
    }

    @Test("a data container is not a parameter container")
    func dataIsNotParameters() {
        let data = PtpContainerHeader.data(code: 1, transactionID: 1, payloadLength: 0).encoded
        #expect(throws: DeviceError.self) { try PtpParameterContainer.decode(data) }
    }

    @Test("names for logs")
    func names() {
        #expect(PtpOperation.getObjectPropList.description == "GetObjectPropList")
        #expect(PtpOperation(rawValue: 0x1234).description == "0x1234")
        #expect(PtpResponseCode.storeFull.description == "StoreFull")
        #expect(PtpResponseCode(rawValue: 0x2999).description == "0x2999")
        #expect(MtpResponseError(operation: .deleteObject, code: .accessDenied).description == "MTP DeleteObject failed: AccessDenied")
    }
}

@Suite("PTP datasets (P2-01)")
struct PtpDatasetTests {
    @Test("DeviceInfo round-trips and answers supports()")
    func deviceInfo() throws {
        var info = PtpDeviceInfo()
        info.operations = [0x1001, 0x9805, 0x95C1]
        info.manufacturer = "samsung"
        info.model = "SM-S918B"
        info.serialNumber = "R5CT20ABCDE"
        let back = try PtpDeviceInfo.decode(try info.encoded())
        #expect(back == info)
        #expect(back.supports(.getPartialObject64))
        #expect(!back.supports(.beginEditObject))
        #expect(throws: DeviceError.self) { try PtpDeviceInfo.decode(Data([1, 2, 3])) }
    }

    @Test("StorageInfo round-trips; removable types")
    func storageInfo() throws {
        let info = PtpStorageInfo(storageType: 4, maxCapacity: 64 << 30, freeSpace: 1 << 30,
                                  storageDescription: "SD card", volumeLabel: "1234-ABCD")
        #expect(try PtpStorageInfo.decode(try info.encoded()) == info)
        #expect(info.isRemovable)
        #expect(!PtpStorageInfo(maxCapacity: 1, freeSpace: 1, storageDescription: "x").isRemovable)
        #expect(throws: DeviceError.self) { try PtpStorageInfo.decode(Data([1])) }
    }

    @Test("ObjectInfo round-trips; devices that stop after the name are accepted")
    func objectInfo() throws {
        var info = PtpObjectInfo()
        info.storageID = 0x0001_0001
        info.format = PtpObjectFormat.association
        info.parent = 5
        info.filename = "DCIM"
        info.dateModified = "20240102T030405"
        let encoded = try info.encoded()
        #expect(try PtpObjectInfo.decode(encoded) == info)
        #expect(info.isFolder)
        // Cut right after the filename.
        var short = PtpObjectInfo()
        short.filename = "a"
        let full = try short.encoded()
        let cut = full.prefix(full.count - 3)
        #expect(try PtpObjectInfo.decode(cut).filename == "a")
        #expect(throws: DeviceError.self) { try PtpObjectInfo.decode(Data(count: 10)) }
    }

    @Test("ObjectPropList decodes in pieces split at every byte")
    func propListStreaming() throws {
        let elements = (1...20).flatMap { handle in
            [PtpPropListElement(handle: UInt32(handle), property: PtpObjectProperty.objectFileName, dataType: PtpDataType.string, value: .string("file \(handle).jpg")),
             PtpPropListElement(handle: UInt32(handle), property: PtpObjectProperty.objectSize, dataType: PtpDataType.uint64, value: .integer(UInt64(handle) << 33))]
        }
        let data = try PtpPropListElement.encode(elements)
        for step in [1, 3, 7, 64, data.count] {
            var decoder = PtpPropListDecoder()
            var out: [PtpPropListElement] = []
            var offset = 0
            while offset < data.count {
                decoder.append(data.subdata(in: offset..<min(offset + step, data.count)))
                out += try decoder.drain()
                offset += step
            }
            #expect(out == elements, "step \(step)")
            #expect(decoder.isComplete)
            #expect(decoder.announcedCount == 40)
        }
        var empty = PtpPropListDecoder()
        #expect(try empty.drain().isEmpty)
        #expect(!empty.isComplete)
    }
}
