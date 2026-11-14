import AdbKit
import DroidCore
import Foundation
import Testing
@testable import UsbKit

@Suite("UsbPacketLink framing")
struct UsbPacketLinkTests {
    let toDevice = MemoryUsbPipe(maxPacketSize: 512, recordTransfers: true)
    let fromDevice = MemoryUsbPipe(maxPacketSize: 512)
    var link: UsbPacketLink { UsbPacketLink(input: fromDevice, output: toDevice) }

    @Test("header and payload are separate transfers; a whole-packet payload gets a ZLP")
    func sendFraming() async throws {
        let link = self.link
        try await link.send(AdbMessage(.okay, 1, 2))
        try await link.send(AdbMessage(.wrte, 1, 2, Data(repeating: 7, count: 100)))
        try await link.send(AdbMessage(.wrte, 1, 2, Data(repeating: 8, count: 1024)))
        #expect(await toDevice.transferLengths == [24, 24, 100, 24, 1024, 0])
        // The device reads exactly what adbd would: header, payload.
        let header = try await toDevice.read(maxLength: 512, timeout: nil)
        #expect(try AdbMessage.decodeHeader([UInt8](header)).command == .okay)
    }

    @Test("checksums are written until the peer says it does not need them")
    func checksums() async throws {
        let link = self.link
        try await link.send(AdbMessage(.wrte, 1, 2, Data([1, 2, 3])))
        await link.setChecksumRequired(false)
        try await link.send(AdbMessage(.wrte, 1, 2, Data([1, 2, 3])))
        let first = try await toDevice.read(maxLength: 512, timeout: nil)
        _ = try await toDevice.read(maxLength: 512, timeout: nil)
        let second = try await toDevice.read(maxLength: 512, timeout: nil)
        #expect(first[16] == 6)
        #expect(second[16] == 0)
    }

    @Test("receives header and payload sent as separate transfers, skipping stray ZLPs")
    func receive() async throws {
        let link = self.link
        let big = AdbMessage(.wrte, 5, 6, Data((0..<2048).map { UInt8(truncatingIfNeeded: $0) }))
        try await fromDevice.write(Data(), timeout: nil)
        try await fromDevice.write(big.encodedHeader(), timeout: nil)
        try await fromDevice.write(big.payload, timeout: nil)
        try await fromDevice.write(Data(), timeout: nil) // ZLP after a whole-packet payload
        let small = AdbMessage(.okay, 5, 6)
        try await fromDevice.write(small.encodedHeader(), timeout: nil)
        #expect(try await link.receive() == big)
        #expect(try await link.receive() == small)
    }

    @Test("receives a device that packs header and payload into one transfer")
    func packed() async throws {
        let link = self.link
        let one = AdbMessage(.wrte, 5, 6, Data("hello".utf8))
        let two = AdbMessage(.okay, 5, 6)
        try await fromDevice.write(one.encoded() + two.encodedHeader(), timeout: nil)
        #expect(try await link.receive() == one)
        #expect(try await link.receive() == two)
    }

    @Test("a dropped link or garbage maps to DeviceError")
    func errors() async throws {
        let link = self.link
        try await fromDevice.write(Data(repeating: 0xAB, count: 24), timeout: nil)
        await #expect(throws: DeviceError.self) { _ = try await link.receive() }
        await fromDevice.close()
        await #expect(throws: DeviceError.disconnected) { _ = try await link.receive() }
        await toDevice.close()
        await #expect(throws: DeviceError.disconnected) { try await link.send(AdbMessage(.okay, 1, 1)) }
    }

    @Test("close aborts both pipes and calls the close hook once")
    func close() async throws {
        let closed = Counter()
        let link = UsbPacketLink(channels: UsbInterfaceChannels(bulkIn: fromDevice, bulkOut: toDevice) { await closed.bump() })
        let pending = Task { try await link.receive() }
        try await Task.sleep(for: .milliseconds(20))
        await link.close()
        await link.close()
        await #expect(throws: DeviceError.disconnected) { _ = try await pending.value }
        #expect(await closed.value == 1)
        await #expect(throws: DeviceError.disconnected) { try await link.send(AdbMessage(.okay, 1, 1)) }
    }

    @Test("concurrent sends never interleave a header with another packet's payload")
    func concurrentSends() async throws {
        let link = self.link
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask { try await link.send(AdbMessage(.wrte, UInt32(i), 0, Data(repeating: UInt8(i), count: 700))) }
            }
            try await group.waitForAll()
        }
        for _ in 0..<16 {
            let header = try AdbMessage.decodeHeader([UInt8](try await toDevice.read(maxLength: 512, timeout: nil)))
            let payload = try await toDevice.read(maxLength: Int(header.payloadLength), timeout: nil)
            #expect(payload == Data(repeating: UInt8(header.arg0), count: 700))
        }
    }

    @Test("AdbConnection handshakes and opens a stream over USB pipes")
    func adbConnectionOverUsb() async throws {
        let device = FakeAdbd(input: toDevice, output: fromDevice)
        let deviceTask = Task { try await device.run() }
        let connection = try await AdbConnection.connect(link: link, key: try AdbKey.generate(), keyName: "test")
        #expect(connection.banner.properties["ro.product.model"] == "Pixel 9")
        let stream = try await connection.open("echo:")
        try await stream.write(Data(repeating: 0x5A, count: 4096))
        var echoed = Data()
        while echoed.count < 4096, let chunk = try await stream.read() { echoed.append(chunk) }
        #expect(echoed == Data(repeating: 0x5A, count: 4096))
        await connection.close()
        deviceTask.cancel()
    }

    actor Counter {
        var value = 0
        func bump() { value += 1 }
    }
}

/// Just enough adbd to accept CNXN and echo one stream, reading the way adbd's
/// FunctionFS code does: a 24-byte header transfer, then the payload.
struct FakeAdbd {
    let input: MemoryUsbPipe
    let output: MemoryUsbPipe

    func run() async throws {
        let link = UsbPacketLink(input: input, output: output)
        await link.setChecksumRequired(false)
        while true {
            let message = try await link.receive()
            switch message.command {
            case .cnxn:
                try await link.send(AdbMessage(.cnxn, AdbMessage.version, AdbMessage.maxPayload,
                                               Data("device::ro.product.model=Pixel 9;features=shell_v2".utf8)))
            case .open:
                try await link.send(AdbMessage(.okay, 100, message.arg0))
            case .wrte:
                try await link.send(AdbMessage(.okay, 100, message.arg0))
                try await link.send(AdbMessage(.wrte, 100, message.arg0, message.payload))
            default:
                break
            }
        }
    }
}
