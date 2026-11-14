import CryptoKit
import DroidCore
import Foundation
import Testing
@testable import MtpKit
import UsbKit

@Suite("MTP session and USB framing (P2-02)")
struct MtpSessionTests {
    @Test("GetDeviceInfo + OpenSession, then transaction ids count up from 1")
    func open() async throws {
        let device = FakeMtpDevice()
        let task = await device.start()
        let session = try await MtpSession.open(channels: device.channels)
        #expect(session.deviceInfo.model == "Pixel 9")
        #expect(session.supports(.getObjectPropList))
        #expect(!session.supports(.copyObject) == false)
        #expect(try await session.storageIDs() == [0x0001_0001])
        #expect(try await session.storageInfo(0x0001_0001).storageDescription == "Internal shared storage")
        #expect(await device.operations.prefix(3) == [0x1001, 0x1002, 0x1004])
        await session.close()
        await session.close()
        await #expect(throws: DeviceError.disconnected) { _ = try await session.storageIDs() }
        task.cancel()
    }

    @Test("a session left open by an earlier run is reused (SessionAlreadyOpen)")
    func alreadyOpen() async throws {
        let device = FakeMtpDevice()
        let task = await device.start()
        let first = try await MtpSession.open(channels: device.channels)
        _ = first // not closed: the phone still thinks a session is open
        let second = try await MtpSession.open(channels: device.channels)
        #expect(try await second.storageIDs().count == 1)
        task.cancel()
    }

    @Test("a refused GetDeviceInfo fails the open and releases the interface")
    func refusedOpen() async throws {
        let device = FakeMtpDevice()
        await device.setForced(.getDeviceInfo, .generalError)
        let task = await device.start()
        await #expect(throws: DeviceError.protocolError("MTP GetDeviceInfo failed: GeneralError")) {
            _ = try await MtpTransport.open(channels: device.channels)
        }
        task.cancel()
    }

    @Test("concurrent calls run one at a time and all succeed")
    func serialized() async throws {
        let device = FakeMtpDevice()
        let task = await device.start()
        let session = try await MtpSession.open(channels: device.channels)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<32 { group.addTask { try await session.storageIDs().count } }
            for try await count in group { #expect(count == 1) }
        }
        #expect(await device.violations.isEmpty)
        await session.close()
        task.cancel()
    }

    @Test("whole-packet containers get a ZLP in both directions; a device that forgets it still works",
          arguments: [false, true])
    func zeroLengthPackets(omitZLP: Bool) async throws {
        // 500 payload + 12 header = 512: exactly one packet.
        let payload = Data(repeating: 0x42, count: 500)
        let h = try await Harness.make(FakeMtpDevice.Profile(omitZLP: omitZLP)) {
            await $0.seed("p.bin", contents: .bytes(payload))
        }
        #expect(try await h.pull(h.path("p.bin")) == payload)
        _ = try await h.push(h.path("q.bin"), payload)
        #expect(try await h.pull(h.path("q.bin")) == payload)
        await h.finish() // the fake checks the host's ZLPs and alignment
    }

    @Test("multi-transfer data phases send whole packets until the last (USB 3, 1024-byte packets)")
    func alignment() async throws {
        let payload = Data((0..<(3 << 20) + 777).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let h = try await Harness.make(FakeMtpDevice.Profile(maxPacketSize: 1024))
        _ = try await h.push(h.path("a.bin"), payload)
        #expect(try await h.pull(h.path("a.bin")) == payload)
        await h.finish()
    }

    @Test("a sink error is reported after the data phase is drained, and the session stays usable")
    func sinkError() async throws {
        let h = try await Harness.make { await $0.seed("f.bin", contents: .bytes(Data(count: 3 << 20))) }
        struct DiskFull: Error {}
        let handle = try #require(await h.device.handle(for: "f.bin"))
        await #expect(throws: DiskFull.self) {
            _ = try await h.transport.session.partialObject64(handle, offset: 0, length: 3 << 20) { _ in throw DiskFull() }
        }
        #expect(try await h.transport.storages().count == 1)
        await h.finish()
    }
}

@Suite("MTP listing (P2-03)")
struct MtpListingTests {
    @Test("FR-04: a 10,000-file folder lists completely in batches of 500",
          arguments: [FakeMtpDevice.Profile.android, .bare])
    func largeFolder(profile: FakeMtpDevice.Profile) async throws {
        let h = try await Harness.make(profile) { device in
            await device.seedFolder("many", count: 10_000)
        }
        let clock = ContinuousClock()
        let start = clock.now
        var firstPage: Duration?
        var total = 0
        var batches: [Int] = []
        var names = Set<String>()
        for try await batch in h.transport.list(h.path("many")) {
            if firstPage == nil { firstPage = clock.now - start }
            total += batch.count
            batches.append(batch.count)
            batch.forEach { names.insert($0.name) }
        }
        #expect(total == 10_000)
        #expect(names.count == 10_000)
        #expect(batches.count == 20)
        #expect(batches.allSatisfy { $0 == 500 })
        print("MTP 10,000 files (\(profile.propList ? "GetObjectPropList" : "GetObjectInfo")): first page \(firstPage!), all \(clock.now - start)")
        // The listing filled the cache: a file in it resolves without listing again.
        let before = await h.device.operations.count
        _ = try await h.transport.stat(h.path("many/file-05000.txt"))
        #expect(await h.device.operations.count - before <= 2)
        await h.finish()
    }

    @Test("a phone that refuses GetObjectPropList for folders falls back to GetObjectInfo")
    func refusedPropList() async throws {
        let h = try await Harness.make { device in
            await device.seed("d/one.txt", contents: .bytes(Data("1".utf8)))
            await device.seed("d/two.txt", contents: .bytes(Data("22".utf8)))
        }
        await h.device.setForced(.getObjectPropList, .specificationByDepthUnsupported)
        let entries = try await h.transport.listAll(Harness.internalRoot)
        #expect(entries.map(\.name) == ["d"])
        #expect(await h.transport.usePropList == false)
        #expect(try await h.transport.listAll(h.path("d")).map(\.size).sorted() == [1, 2])
        await h.finish()
    }

    @Test("the storage root lists only its own storage, though Android answers for all")
    func rootPerStorage() async throws {
        let h = try await Harness.make(storages: [
            0x0001_0001: PtpStorageInfo(maxCapacity: 1 << 30, freeSpace: 1 << 29, storageDescription: "Internal shared storage"),
            0x0002_0001: PtpStorageInfo(storageType: 4, maxCapacity: 1 << 30, freeSpace: 1 << 29,
                                        storageDescription: "SD card", volumeLabel: "ABCD-1234"),
        ]) { device in
            await device.seed("Internal.txt", contents: .bytes(Data("i".utf8)))
            await device.seed("Card.txt", storage: 0x0002_0001, contents: .bytes(Data("c".utf8)))
        }
        #expect(try await h.transport.listAll(Harness.internalRoot).map(\.name) == ["Internal.txt"])
        let card = RemotePath("/storage/ABCD-1234")
        #expect(try await h.transport.listAll(card).map(\.name) == ["Card.txt"])
        _ = try await h.push(card.appending("new.txt"), Data("n".utf8))
        #expect(await h.device.object(at: "new.txt") == nil)
        #expect(await h.device.names(in: "").contains("new.txt"))
        // Move across storages.
        _ = try await h.transport.rename(card.appending("new.txt"), to: h.path("moved.txt"))
        #expect(try await h.pull(h.path("moved.txt")) == Data("n".utf8))
        await h.finish()
    }

    @Test("names that cannot be part of a path are skipped")
    func unaddressable() {
        #expect(!MtpNode.isAddressable(""))
        #expect(!MtpNode.isAddressable(".."))
        #expect(!MtpNode.isAddressable("a/b"))
        #expect(MtpNode.isAddressable("ok.txt"))
        var info = PtpObjectInfo()
        info.filename = "a/b"
        #expect(MtpNode.from(handle: 1, info: info, size: 0, parentPath: .root, timeZone: .current) == nil)
        #expect(MtpNode.from(handle: 1, properties: [:], parentPath: .root, timeZone: .current) == nil)
    }

    @Test("the cache forgets subtrees and trusts listings only briefly")
    func cache() {
        var cache = MtpObjectCache()
        let dir = RemotePath("/s/d")
        let node = { (h: UInt32, p: String, k: EntryKind) in
            MtpNode(handle: h, storageID: 1, parent: 0, path: RemotePath(p), kind: k, size: 0, mtime: Date())
        }
        cache.setChildren(of: RemotePath("/s"), [node(1, "/s/d", .directory)])
        cache.setChildren(of: dir, [node(2, "/s/d/a", .file), node(3, "/s/d/b", .directory)])
        cache.setChildren(of: RemotePath("/s/d/b"), [node(4, "/s/d/b/c", .file)])
        #expect(cache.count == 4)
        #expect(cache.isFreshlyListed(dir))
        #expect(!cache.isFreshlyListed(dir, now: Date().addingTimeInterval(60)))
        cache.setChildren(of: dir, [node(2, "/s/d/a", .file)])
        #expect(cache.node(handle: 3) == nil)
        #expect(cache.node(handle: 4) == nil)
        cache.insert(node(2, "/s/d/renamed", .file))
        #expect(cache.node(at: RemotePath("/s/d/a")) == nil)
        #expect(cache.node(at: RemotePath("/s/d/renamed"))?.handle == 2)
        cache.remove(dir)
        #expect(cache.node(handle: 1) == nil)
        #expect(cache.node(handle: 2) == nil)
        #expect(cache.count == 0)
        cache.invalidateListing(RemotePath("/s"))
        #expect(!cache.isFreshlyListed(RemotePath("/s")))
        cache.removeAll()
        #expect(cache.count == 0)
    }
}

@Suite("MTP events (P2-06)")
struct MtpEventTests {
    @Test("FR-11: a photo taken on the phone becomes a hint for its folder")
    func objectAdded() async throws {
        let h = try await Harness.make { await $0.seed("DCIM/Camera/old.jpg", contents: .bytes(Data("o".utf8))) }
        _ = try await h.transport.listAll(h.path("DCIM/Camera"))
        let camera = h.path("DCIM/Camera")
        async let hint = waitForHint(h.transport) { $0 == .changed(camera) }
        try await Task.sleep(for: .milliseconds(50))
        await h.device.phoneAdds("DCIM/Camera/new.jpg", contents: Data("n".utf8))
        #expect(await hint == .changed(camera))
        #expect(try await h.transport.listAll(camera).map(\.name).sorted() == ["new.jpg", "old.jpg"])
        await h.finish()
    }

    @Test("additions in folders not yet browsed point at the storage root")
    func objectAddedUnknownParent() async throws {
        let h = try await Harness.make { await $0.seed("Deep/Down") }
        _ = try await h.transport.storages()
        async let hint = waitForHint(h.transport) { $0 == .changed(Harness.internalRoot) }
        try await Task.sleep(for: .milliseconds(50))
        await h.device.phoneAdds("Deep/Down/x.txt", contents: Data("x".utf8))
        #expect(await hint == .changed(Harness.internalRoot))
        await h.finish()
    }

    @Test("removals, changes and storage events")
    func otherEvents() async throws {
        let h = try await Harness.make { await $0.seed("Music/song.mp3", contents: .bytes(Data("s".utf8))) }
        _ = try await h.transport.listAll(h.path("Music"))
        let music = h.path("Music")
        async let removed = waitForHint(h.transport) { $0 == .changed(music) }
        try await Task.sleep(for: .milliseconds(50))
        await h.device.phoneRemoves("Music/song.mp3")
        #expect(await removed == .changed(music))

        async let unknown = waitForHint(h.transport) { $0 == .changed(.root) }
        try await Task.sleep(for: .milliseconds(50))
        await h.device.sendEvent(.objectRemoved, 9999)
        #expect(await unknown == .changed(.root))

        let folder = try #require(await h.device.handle(for: "Music"))
        async let changed = waitForHint(h.transport) { $0 == .changed(Harness.internalRoot) }
        try await Task.sleep(for: .milliseconds(50))
        await h.device.sendEvent(.objectInfoChanged, folder)
        #expect(await changed == .changed(Harness.internalRoot))

        async let storages = waitForHint(h.transport) { $0 == .storagesChanged }
        try await Task.sleep(for: .milliseconds(50))
        await h.device.addStorage(0x0002_0001, PtpStorageInfo(storageType: 4, maxCapacity: 1 << 30, freeSpace: 1 << 30,
                                                              storageDescription: "SD card", volumeLabel: "AAAA-0001"))
        #expect(await storages == .storagesChanged)
        #expect(try await h.transport.storages().count == 2)
        await h.finish()
    }

    @Test("the change stream ends when the phone is unplugged")
    func endsOnUnplug() async throws {
        let h = try await Harness.make()
        await h.device.unplug()
        var count = 0
        for await _ in h.transport.changes { count += 1 }
        #expect(count >= 0)
        h.task.cancel()
    }
}

@Suite("MTP large files and cancellation (P2-04)")
struct MtpLargeFileTests {
    @Test("a 48 MB file goes over and back with matching SHA-256")
    func sha256RoundTrip() async throws {
        let h = try await Harness.make()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var random = SystemRandomNumberGenerator()
        let block = Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255, using: &random) })
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let out = try FileHandle(forWritingTo: source)
        for i in 0..<48 { try out.write(contentsOf: block.subdata(in: (i * 4099 % 1000)..<block.count) + block.prefix(i * 4099 % 1000)) }
        try out.close()
        defer { try? FileManager.default.removeItem(at: source) }

        let input = try FileHandle(forReadingFrom: source)
        let progress = Progress()
        let entry = try await h.transport.write(h.path("big.bin"), from: input, mtime: nil, progress: progress)
        try input.close()
        #expect(entry.size == 48 << 20)
        #expect(progress.completedUnitCount == 48 << 20)

        let back = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: back.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: back) }
        let sink = try FileHandle(forWritingTo: back)
        let readProgress = Progress()
        try await h.transport.read(h.path("big.bin"), to: sink, range: nil, progress: readProgress)
        try sink.close()
        #expect(readProgress.completedUnitCount == 48 << 20)
        #expect(try sha256(of: source) == sha256(of: back))
        await h.finish()
    }

    @Test("files of 4 GB and more: ObjectInfo says 0xFFFFFFFF, the data header too, 64-bit offsets read back")
    func overFourGigabytes() async throws {
        let h = try await Harness.make()
        let size: UInt64 = (4 << 30) + 1536 // ends on a whole packet: the host must send a ZLP
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let sparse = try FileHandle(forWritingTo: url)
        try sparse.truncate(atOffset: size) // APFS keeps it sparse: zeros, no disk used
        try sparse.close()
        let input = try FileHandle(forReadingFrom: url)
        let entry = try await h.transport.write(h.path("video.mp4"), from: input, mtime: nil, progress: Progress())
        try input.close()
        #expect(entry.size == size)
        #expect(await h.device.lastDataHeaderLength == PtpContainerHeader.unknownLength)
        #expect(await h.device.object(at: "video.mp4")?.content.size == size)
        let tail = try await h.pull(h.path("video.mp4"), range: (size - 3000)..<size)
        #expect(tail == Data(count: 3000))
        #expect(try await h.transport.listAll(Harness.internalRoot).first?.size == size)
        await h.finish()
    }

    @Test("GetObject of a file over 4 GB reads a 0xFFFFFFFF data phase (no partial reads)")
    func getObjectOverFourGigabytes() async throws {
        let size: UInt64 = (4 << 30) + 100
        let h = try await Harness.make(.bare) { await $0.seed("big.iso", contents: .zeros(size)) }
        let entries = try await h.transport.listAll(Harness.internalRoot)
        // ObjectInfo says 0xFFFFFFFF and this device has no GetObjectPropValue to ask the real size.
        #expect(entries.first?.size == 0xFFFF_FFFF)
        let tail = try await h.pull(h.path("big.iso"), range: (size - 50)..<size)
        #expect(tail == Data(count: 50))
        #expect(try await h.transport.storages().count == 1) // still in step after the 0xFFFFFFFF phase
        await h.finish()
    }

    @Test("the full 6 GB round trip of FR-07, SHA-256 checked",
          .enabled(if: ProcessInfo.processInfo.environment["DROIDDRIVE_MTP_6GB"] != nil))
    func sixGigabytes() async throws {
        let h = try await Harness.make()
        let size: UInt64 = 6 << 30
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let sparse = try FileHandle(forWritingTo: url)
        try sparse.truncate(atOffset: size)
        try sparse.close()
        let input = try FileHandle(forReadingFrom: url)
        _ = try await h.transport.write(h.path("six.bin"), from: input, mtime: nil, progress: Progress())
        try input.close()
        let back = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: back.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: back) }
        let out = try FileHandle(forWritingTo: back)
        try await h.transport.read(h.path("six.bin"), to: out, range: nil, progress: Progress())
        try out.close()
        #expect(try sha256(of: url) == sha256(of: back))
        await h.finish()
    }

    @Test("cancelling an upload sends a PTP cancel, removes the partial file, and the session goes on")
    func cancelUpload() async throws {
        let h = try await Harness.make()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let sparse = try FileHandle(forWritingTo: url)
        try sparse.truncate(atOffset: 512 << 20)
        try sparse.close()
        let input = try FileHandle(forReadingFrom: url)
        let progress = Progress()
        let transport = h.transport
        let upload = Task {
            try await transport.write(h.path("cancel-me.bin"), from: input, mtime: nil, progress: progress)
        }
        while progress.completedUnitCount < 8 << 20 { try await Task.sleep(for: .milliseconds(5)) }
        upload.cancel()
        await #expect(throws: CancellationError.self) { _ = try await upload.value }
        try input.close()
        #expect(await h.device.names(in: "").contains("cancel-me.bin") == false)
        _ = try await h.push(h.path("after.txt"), Data("ok".utf8))
        #expect(try await h.pull(h.path("after.txt")) == Data("ok".utf8))
        await h.finish()
    }

    @Test("cancelling a download stops between 1 MB chunks")
    func cancelDownload() async throws {
        let h = try await Harness.make { await $0.seed("long.bin", contents: .zeros(256 << 20)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let out = try FileHandle(forWritingTo: url)
        let progress = Progress()
        let transport = h.transport
        let download = Task { try await transport.read(h.path("long.bin"), to: out, range: nil, progress: progress) }
        while progress.completedUnitCount < 4 << 20 { try await Task.sleep(for: .milliseconds(5)) }
        download.cancel()
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(progress.completedUnitCount < 256 << 20)
        try out.close()
        #expect(try await h.transport.storages().count == 1)
        await h.finish()
    }
}
