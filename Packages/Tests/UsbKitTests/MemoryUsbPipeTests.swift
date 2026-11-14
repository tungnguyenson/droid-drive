import Foundation
import Testing
@testable import UsbKit

@Suite("MemoryUsbPipe transfer semantics")
struct MemoryUsbPipeTests {
    @Test("a short packet ends a read even when more was asked for")
    func shortPacketEndsRead() async throws {
        let pipe = MemoryUsbPipe(maxPacketSize: 64)
        try await pipe.write(Data(repeating: 1, count: 10), timeout: nil)
        try await pipe.write(Data(repeating: 2, count: 10), timeout: nil)
        #expect(try await pipe.read(maxLength: 1024, timeout: nil) == Data(repeating: 1, count: 10))
        #expect(try await pipe.read(maxLength: 1024, timeout: nil) == Data(repeating: 2, count: 10))
    }

    @Test("whole-packet transfers run on into the next one until a short packet")
    func fullPacketsContinue() async throws {
        let pipe = MemoryUsbPipe(maxPacketSize: 64)
        try await pipe.write(Data(repeating: 1, count: 128), timeout: nil)
        try await pipe.write(Data(repeating: 2, count: 3), timeout: nil)
        let got = try await pipe.read(maxLength: 1024, timeout: nil)
        #expect(got.count == 131)
    }

    @Test("a zero-length packet ends a read and is consumed with it")
    func zlpEndsRead() async throws {
        let pipe = MemoryUsbPipe(maxPacketSize: 64)
        try await pipe.write(Data(repeating: 1, count: 64), timeout: nil)
        try await pipe.write(Data(), timeout: nil)
        try await pipe.write(Data([9]), timeout: nil)
        #expect(try await pipe.read(maxLength: 1024, timeout: nil).count == 64)
        #expect(try await pipe.read(maxLength: 1024, timeout: nil) == Data([9]))
    }

    @Test("a read filled exactly leaves the following ZLP for the next read")
    func filledReadLeavesZLP() async throws {
        let pipe = MemoryUsbPipe(maxPacketSize: 64)
        try await pipe.write(Data(repeating: 1, count: 64), timeout: nil)
        try await pipe.write(Data(), timeout: nil)
        #expect(try await pipe.read(maxLength: 64, timeout: nil).count == 64)
        #expect(try await pipe.read(maxLength: 64, timeout: nil).isEmpty)
    }

    @Test("a read that would split a packet overflows")
    func overflow() async throws {
        let pipe = MemoryUsbPipe(maxPacketSize: 64)
        try await pipe.write(Data(repeating: 1, count: 100), timeout: nil)
        await #expect(throws: UsbError.overflow) { _ = try await pipe.read(maxLength: 24, timeout: nil) }
    }

    @Test("a read stopping on a packet boundary inside a transfer leaves the rest")
    func partialOnBoundary() async throws {
        let pipe = MemoryUsbPipe(maxPacketSize: 64)
        try await pipe.write(Data(repeating: 1, count: 130), timeout: nil)
        #expect(try await pipe.read(maxLength: 128, timeout: nil).count == 128)
        #expect(try await pipe.read(maxLength: 128, timeout: nil).count == 2)
    }

    @Test("reads wait for data, time out, abort and see a disconnect")
    func waiting() async throws {
        let pipe = MemoryUsbPipe(maxPacketSize: 64)
        await #expect(throws: UsbError.timedOut) { _ = try await pipe.read(maxLength: 64, timeout: .milliseconds(20)) }
        let reader = Task { try await pipe.read(maxLength: 64, timeout: nil) }
        try await Task.sleep(for: .milliseconds(20))
        try await pipe.write(Data([1, 2]), timeout: nil)
        #expect(try await reader.value == Data([1, 2]))

        let aborted = Task { try await pipe.read(maxLength: 64, timeout: nil) }
        try await Task.sleep(for: .milliseconds(20))
        await pipe.abort()
        await #expect(throws: UsbError.aborted) { _ = try await aborted.value }

        let cancelled = Task { try await pipe.read(maxLength: 64, timeout: nil) }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        await #expect(throws: UsbError.aborted) { _ = try await cancelled.value }

        await pipe.close()
        await #expect(throws: UsbError.disconnected) { _ = try await pipe.read(maxLength: 64, timeout: nil) }
        await #expect(throws: UsbError.disconnected) { try await pipe.write(Data([1]), timeout: nil) }
    }

    @Test("a full queue blocks the writer until the reader drains it")
    func backpressure() async throws {
        let pipe = MemoryUsbPipe(maxPacketSize: 64, capacity: 128, recordTransfers: true)
        try await pipe.write(Data(repeating: 1, count: 128), timeout: nil)
        await #expect(throws: UsbError.timedOut) { try await pipe.write(Data(repeating: 2, count: 64), timeout: .milliseconds(20)) }
        let writer = Task { try await pipe.write(Data(repeating: 3, count: 10), timeout: nil) }
        _ = try await pipe.read(maxLength: 128, timeout: nil)
        try await writer.value
        #expect(try await pipe.read(maxLength: 128, timeout: nil) == Data(repeating: 3, count: 10))
        #expect(await pipe.transferLengths == [128, 10])
    }
}

@Suite("AsyncLock")
struct AsyncLockTests {
    @Test("serializes critical sections in FIFO order")
    func serializes() async throws {
        let lock = AsyncLock()
        let log = Log()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    await lock.withLock {
                        await log.append("in \(i)")
                        try? await Task.sleep(for: .milliseconds(1))
                        await log.append("out \(i)")
                    }
                }
            }
        }
        let entries = await log.entries
        #expect(entries.count == 40)
        for pair in stride(from: 0, to: entries.count, by: 2) {
            #expect(entries[pair].dropFirst(3) == entries[pair + 1].dropFirst(4))
        }
    }

    @Test("releases the lock when the body throws")
    func releasesOnThrow() async throws {
        let lock = AsyncLock()
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await lock.withLock { throw Boom() } }
        #expect(await lock.withLock { 42 } == 42)
    }

    actor Log {
        var entries: [String] = []
        func append(_ s: String) { entries.append(s) }
    }
}
