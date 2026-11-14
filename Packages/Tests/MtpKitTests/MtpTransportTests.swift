import DroidCore
import Foundation
import Testing
@testable import MtpKit
import UsbKit

/// MtpTransport against the fake phone, with the checks `EmulatorTests` runs for
/// AdbTransport (plan P2-07).
@Suite("MtpTransport on a fake Android phone")
struct MtpTransportTests {
    @Test("device info prefers the USB serial; storages map to ADB's paths")
    func storages() async throws {
        let h = try await Harness.make(storages: [
            0x0001_0001: PtpStorageInfo(maxCapacity: 128 << 30, freeSpace: 64 << 30, storageDescription: "Internal shared storage"),
            0x0002_0001: PtpStorageInfo(storageType: 4, maxCapacity: 32 << 30, freeSpace: 1 << 30,
                                        storageDescription: "SD card", volumeLabel: "1234-ABCD"),
            0x0003_0001: PtpStorageInfo(storageType: 4, maxCapacity: 8 << 30, freeSpace: 1 << 30, storageDescription: "USB drive"),
        ])
        #expect(h.transport.info == DeviceInfo(serial: "USBSERIAL", manufacturer: "Google", model: "Pixel 9", androidVersion: nil))
        let storages = try await h.transport.storages()
        #expect(storages.map(\.root.string) == ["/storage/emulated/0", "/storage/1234-ABCD", "/storage/00030001"])
        #expect(storages.map(\.kind) == [.internal, .removable, .removable])
        #expect(storages[0].capacity == 128 << 30 && storages[0].free == 64 << 30)
        #expect(storages[0].id == "00010001")
        #expect(DomainIdentifier(serial: "s", storage: storages[1]).root == storages[1].root)
        await h.finish()
    }

    @Test("the MTP serial is used when no USB serial is given")
    func mtpSerial() async throws {
        let device = FakeMtpDevice()
        let task = await device.start()
        let transport = try await MtpTransport.open(channels: device.channels)
        #expect(transport.info.serial == "MTPSERIAL")
        await transport.close()
        task.cancel()
    }

    @Test("lists folders with sizes, kinds, mtimes and handles", arguments: [FakeMtpDevice.Profile.android, .bare])
    func listing(profile: FakeMtpDevice.Profile) async throws {
        let h = try await Harness.make(profile) { device in
            await device.seed("DCIM/Camera/IMG_0001.jpg", contents: .bytes(Data(repeating: 1, count: 1234)))
            await device.seed("DCIM/Camera/IMG_0002.jpg", contents: .bytes(Data(repeating: 2, count: 10)))
            await device.seed("Download")
        }
        let root = try await h.transport.listAll(Harness.internalRoot)
        #expect(root.map(\.name).sorted() == ["DCIM", "Download"])
        #expect(root.allSatisfy { $0.kind == .directory && $0.size == 0 })
        let camera = try await h.transport.listAll(h.path("DCIM/Camera")).sorted { $0.name < $1.name }
        #expect(camera.map(\.name) == ["IMG_0001.jpg", "IMG_0002.jpg"])
        #expect(camera[0].size == 1234)
        #expect(camera[0].kind == .file)
        #expect(camera[0].mtime == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(camera[0].transportKey != nil)
        #expect(camera[0].path == h.path("DCIM/Camera/IMG_0001.jpg"))
        let stat = try await h.transport.stat(h.path("DCIM/Camera/IMG_0002.jpg"))
        #expect(stat.size == 10)
        await h.finish()
    }

    @Test("folders above the storage roots are virtual directories")
    func virtualFolders() async throws {
        let h = try await Harness.make()
        #expect(try await h.transport.listAll(.root).map(\.name) == ["storage"])
        #expect(try await h.transport.listAll(RemotePath("/storage")).map(\.name) == ["emulated"])
        #expect(try await h.transport.stat(RemotePath("/storage")).kind == .directory)
        #expect(try await h.transport.stat(Harness.internalRoot).kind == .directory)
        await #expect(throws: DeviceError.notFound(RemotePath("/sdcard"))) { _ = try await h.transport.stat(RemotePath("/sdcard")) }
        await #expect(throws: DeviceError.permissionDenied(RemotePath("/storage"))) {
            try await h.transport.delete(RemotePath("/storage"), recursive: true)
        }
        await #expect(throws: DeviceError.permissionDenied(RemotePath("/storage"))) {
            try await h.push(RemotePath("/storage/x.txt"), Data("x".utf8))
        }
        await h.finish()
    }

    @Test("write, read back, overwrite, with progress", arguments: [FakeMtpDevice.Profile.android, .bare,
                                                                    FakeMtpDevice.Profile(editOps: false)])
    func roundTrip(profile: FakeMtpDevice.Profile) async throws {
        let h = try await Harness.make(profile)
        let file = h.path("Download/notes.txt")
        _ = try await h.transport.mkdir(file.parent)
        let progress = Progress()
        let written = try await h.push(file, Data("first version".utf8), progress: progress)
        #expect(written.size == 13)
        #expect(progress.completedUnitCount == 13)
        #expect(try await h.pull(file) == Data("first version".utf8))
        let second = try await h.push(file, Data("second, longer version".utf8))
        #expect(second.size == 22)
        #expect(try await h.pull(file) == Data("second, longer version".utf8))
        _ = try await h.push(file, Data("3rd".utf8))
        #expect(try await h.pull(file) == Data("3rd".utf8))
        #expect(await h.device.names(in: "Download") == ["notes.txt"])
        await h.finish()
    }

    @Test("FR-09: a new file keeps the Mac's mtime")
    func mtime() async throws {
        let h = try await Harness.make()
        let when = Date(timeIntervalSince1970: 1_577_953_845)
        let entry = try await h.push(h.path("old.txt"), Data("x".utf8), mtime: when)
        #expect(entry.mtime == when)
        #expect(try await h.transport.stat(h.path("old.txt")).mtime == when)
        #expect(await h.device.object(at: "old.txt")?.modified == "20200102T083045")
        await h.finish()
    }

    @Test("ranged reads", arguments: [FakeMtpDevice.Profile.android, FakeMtpDevice.Profile(partial64: false), .bare])
    func ranges(profile: FakeMtpDevice.Profile) async throws {
        let bytes = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let h = try await Harness.make(profile) { await $0.seed("blob.bin", contents: .bytes(bytes)) }
        #expect(try await h.pull(h.path("blob.bin"), range: 100..<2100) == bytes.subdata(in: 100..<2100))
        #expect(try await h.pull(h.path("blob.bin"), range: 4900..<9000) == bytes.subdata(in: 4900..<5000))
        #expect(try await h.pull(h.path("blob.bin"), range: 6000..<7000).isEmpty)
        #expect(try await h.pull(h.path("blob.bin")) == bytes)
        await h.finish()
    }

    @Test("FR-08: an NFD name from the Mac lands as NFC, and there is one file, not two")
    func vietnameseNames() async throws {
        let h = try await Harness.make()
        let nfc = "Ảnh cưới Đà Lạt.jpg".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        let base = h.path("Pictures")
        _ = try await h.transport.mkdir(base)
        _ = try await h.push(base.appending(nfd), Data("một".utf8))
        _ = try await h.push(base.appending(nfc), Data("hai".utf8))
        let entries = try await h.transport.listAll(base)
        #expect(entries.count == 1)
        #expect(Array(try #require(entries.first).name.utf8) == Array(nfc.utf8))
        #expect(try await h.pull(base.appending(nfc)) == Data("hai".utf8))
        await h.finish()
    }

    @Test("a name an Android app wrote in NFD keeps its bytes and stays addressable")
    func deviceNfdName() async throws {
        let nfd = "Đà Lạt.txt".decomposedStringWithCanonicalMapping
        let h = try await Harness.make { await $0.seed("Notes/\(nfd)", contents: .bytes(Data("nfd".utf8))) }
        let entry = try #require(try await h.transport.listAll(h.path("Notes")).first)
        #expect(Array(entry.name.utf8) == Array(nfd.utf8))
        #expect(try await h.pull(entry.path) == Data("nfd".utf8))
        // The NFC spelling is a different (missing) file on the device.
        await #expect(throws: DeviceError.self) {
            _ = try await h.pull(h.path("Notes").appending(exact: nfd.precomposedStringWithCanonicalMapping))
        }
        await h.finish()
    }

    @Test("malicious names are created, renamed and deleted as literal names")
    func maliciousNames() async throws {
        let h = try await Harness.make()
        let names = try Harness.maliciousNames()
        #expect(names.count >= 10)
        let dir = try await h.transport.mkdir(h.path("evil")).path
        let sentinel = try await h.push(h.path("sentinel.txt"), Data("still here".utf8)).path
        for name in names {
            let path = dir.appending(name)
            _ = try await h.push(path, Data(name.utf8))
            let renamed = try await h.transport.rename(path, to: dir.appending(name + ".moved"))
            #expect(try await h.pull(renamed.path) == Data(name.utf8), "\(name.debugDescription)")
            let folder = try await h.transport.mkdir(dir.appending(name + ".d"))
            try await h.transport.delete(folder.path, recursive: true)
        }
        let listed = Set(try await h.transport.listAll(dir).map(\.name))
        #expect(listed == Set(names.map { $0 + ".moved" }))
        #expect(try await h.pull(sentinel) == Data("still here".utf8))
        await h.finish()
    }

    @Test("rename never overwrites; mkdir over a file is `exists`; missing paths are `notFound`")
    func errors() async throws {
        let h = try await Harness.make()
        _ = try await h.push(h.path("a.txt"), Data("a".utf8))
        _ = try await h.push(h.path("b.txt"), Data("b".utf8))
        await #expect(throws: DeviceError.exists(h.path("b.txt"))) {
            _ = try await h.transport.rename(h.path("a.txt"), to: h.path("b.txt"))
        }
        #expect(try await h.pull(h.path("b.txt")) == Data("b".utf8))
        await #expect(throws: DeviceError.exists(h.path("a.txt"))) { _ = try await h.transport.mkdir(h.path("a.txt")) }
        await #expect(throws: DeviceError.notFound(h.path("nope"))) { _ = try await h.transport.stat(h.path("nope")) }
        await #expect(throws: DeviceError.notFound(h.path("nope"))) { _ = try await h.transport.listAll(h.path("nope")) }
        await #expect(throws: DeviceError.notFound(h.path("nope/x"))) { _ = try await h.pull(h.path("nope/x")) }
        await #expect(throws: DeviceError.notFound(h.path("nope/x.txt").parent)) {
            _ = try await h.transport.rename(h.path("a.txt"), to: h.path("nope/x.txt"))
        }
        await #expect(throws: DeviceError.self) { _ = try await h.transport.listAll(h.path("a.txt")) }
        await #expect(throws: DeviceError.self) { _ = try await h.pull(h.path("")) }
        _ = try await h.transport.mkdir(h.path("folder"))
        await #expect(throws: DeviceError.exists(h.path("folder"))) { try await h.push(h.path("folder"), Data()) }
        await #expect(throws: DeviceError.self) { _ = try await h.pull(h.path("folder")) }
        await #expect(throws: DeviceError.self) {
            _ = try await h.transport.rename(h.path("folder"), to: h.path("folder/inside"))
        }
        await h.finish()
    }

    @Test("mkdir is mkdir -p and idempotent; delete refuses a non-empty folder unless recursive")
    func folders() async throws {
        let h = try await Harness.make()
        let deep = try await h.transport.mkdir(h.path("a/b/c"))
        #expect(deep.kind == .directory)
        #expect(try await h.transport.mkdir(h.path("a/b/c")).path == deep.path)
        _ = try await h.push(h.path("a/b/c/f.txt"), Data("f".utf8))
        await #expect(throws: DeviceError.protocolError("Folder is not empty")) {
            try await h.transport.delete(h.path("a"), recursive: false)
        }
        try await h.transport.delete(h.path("a/b/c/f.txt"), recursive: false)
        try await h.transport.delete(h.path("a/b/c"), recursive: false)
        try await h.transport.delete(h.path("a"), recursive: true)
        #expect(await h.device.names(in: "").isEmpty)
        await #expect(throws: DeviceError.notFound(h.path("a"))) { try await h.transport.delete(h.path("a"), recursive: true) }
        #expect(try await h.transport.mkdir(Harness.internalRoot).kind == .directory)
        await h.finish()
    }

    @Test("move a directory with contents, with and without MoveObject",
          arguments: [FakeMtpDevice.Profile.android, FakeMtpDevice.Profile(move: false), .bare])
    func moveDirectory(profile: FakeMtpDevice.Profile) async throws {
        let h = try await Harness.make(profile)
        _ = try await h.transport.mkdir(h.path("src/inner"))
        _ = try await h.push(h.path("src/inner/f.txt"), Data("f".utf8), mtime: Date(timeIntervalSince1970: 1_600_000_000))
        _ = try await h.transport.mkdir(h.path("dst"))
        let moved = try await h.transport.rename(h.path("src"), to: h.path("dst/src"))
        #expect(moved.kind == .directory)
        #expect(try await h.pull(h.path("dst/src/inner/f.txt")) == Data("f".utf8))
        #expect(try await h.transport.stat(h.path("dst/src/inner/f.txt")).mtime == Date(timeIntervalSince1970: 1_600_000_000))
        await #expect(throws: DeviceError.notFound(h.path("src"))) { _ = try await h.transport.stat(h.path("src")) }
        // Move and rename in one step, also to the storage root.
        _ = try await h.transport.rename(h.path("dst/src/inner/f.txt"), to: h.path("g.txt"))
        #expect(try await h.pull(h.path("g.txt")) == Data("f".utf8))
        await h.finish()
    }

    @Test("a move whose old name is taken at the destination goes through a temporary name")
    func moveWithCollision() async throws {
        let h = try await Harness.make()
        _ = try await h.transport.mkdir(h.path("a"))
        _ = try await h.transport.mkdir(h.path("b"))
        _ = try await h.push(h.path("a/x.txt"), Data("moving".utf8))
        _ = try await h.push(h.path("b/x.txt"), Data("staying".utf8))
        _ = try await h.transport.rename(h.path("a/x.txt"), to: h.path("b/y.txt"))
        #expect(try await h.pull(h.path("b/y.txt")) == Data("moving".utf8))
        #expect(try await h.pull(h.path("b/x.txt")) == Data("staying".utf8))
        #expect(await h.device.names(in: "a").isEmpty)
        await h.finish()
    }

    @Test("rename in place keeps the handle")
    func renameInPlace() async throws {
        let h = try await Harness.make()
        let before = try await h.push(h.path("one.txt"), Data("1".utf8))
        let after = try await h.transport.rename(h.path("one.txt"), to: h.path("two.txt"))
        #expect(after.transportKey == before.transportKey)
        #expect(await h.device.names(in: "") == ["two.txt"])
        await h.finish()
    }

    @Test("device errors map to DeviceError")
    func errorMapping() async throws {
        let h = try await Harness.make()
        _ = try await h.push(h.path("a.txt"), Data("a".utf8))
        await h.device.setForced(.deleteObject, .accessDenied)
        await #expect(throws: DeviceError.permissionDenied(h.path("a.txt"))) { try await h.transport.delete(h.path("a.txt"), recursive: false) }
        await h.device.setForced(.sendObjectInfo, .storeFull)
        await #expect(throws: DeviceError.noSpace(needed: 0, available: 0)) { try await h.push(h.path("b.txt"), Data("b".utf8)) }
        await h.device.setForced(.getStorageIDs, .deviceBusy)
        await #expect(throws: DeviceError.protocolError("MTP GetStorageIDs failed: DeviceBusy")) { _ = try await h.transport.storages() }
        let cases: [(PtpResponseCode, DeviceError)] = [
            (.invalidObjectHandle, .notFound(.root)), (.storeReadOnly, .permissionDenied(.root)),
            (.operationNotSupported, .unsupported("The phone does not support DeleteObject over MTP")),
            (.sessionNotOpen, .disconnected),
            (.objectTooLarge, .unsupported("The phone's storage cannot hold files this large (FAT32 limit)")),
            (.generalError, .protocolError("MTP DeleteObject failed: GeneralError")),
        ]
        for (code, expected) in cases {
            #expect(MtpTransport.deviceError(MtpResponseError(operation: .deleteObject, code: code), path: .root) == expected)
        }
        await h.finish()
    }

    @Test("a big write checks free space first")
    func freeSpace() async throws {
        let h = try await Harness.make(storages: [
            0x0001_0001: PtpStorageInfo(maxCapacity: 1 << 30, freeSpace: 50 << 20, storageDescription: "Internal shared storage"),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 200 << 20) // sparse
        try handle.close()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        await #expect(throws: DeviceError.noSpace(needed: 200 << 20, available: 50 << 20)) {
            _ = try await h.transport.write(h.path("big.bin"), from: input, mtime: nil, progress: Progress())
        }
        await h.finish()
    }

    @Test("a handle deleted behind our back is re-resolved")
    func staleHandle() async throws {
        let h = try await Harness.make { await $0.seed("x.txt", contents: .bytes(Data("old".utf8))) }
        _ = try await h.transport.stat(h.path("x.txt"))
        // The phone replaces the file without telling us (no event).
        await h.device.silentlyReplace("x.txt", with: Data("new!".utf8))
        #expect(try await h.pull(h.path("x.txt")) == Data("new!".utf8))
        await h.finish()
    }

    @Test("unplugging makes calls fail with disconnected")
    func unplug() async throws {
        let h = try await Harness.make()
        _ = try await h.transport.storages()
        await h.device.unplug()
        await #expect(throws: DeviceError.disconnected) { _ = try await h.transport.stat(h.path("x")) }
        await #expect(throws: DeviceError.disconnected) { _ = try await h.transport.storages() }
        h.task.cancel()
    }

    @Test("an interface held by another app is reported busy with its name")
    func busy() {
        #expect(UsbError.exclusiveAccess(UsbHolder(pid: 1, processName: "ptpcamerad")).deviceError == .busy(by: "ptpcamerad"))
        #expect(throws: UsbError.notFound) { _ = try MtpTransport.openChannels(interfaceRegistryID: 0xDEAD_BEEF_0000) }
    }
}

extension FakeMtpDevice {
    func setForced(_ op: PtpOperation, _ code: PtpResponseCode) { forcedResponses[op.rawValue] = code }

    /// Deletes and recreates a file under a new handle, sending no event.
    func silentlyReplace(_ path: String, with data: Data) {
        guard let old = handle(for: path), let object = objects[old] else { return }
        objects[old] = nil
        let new = nextHandle
        nextHandle += 1
        objects[new] = Object(storage: object.storage, parent: object.parent, name: object.name, isDir: false,
                              content: .bytes(data), modified: object.modified)
    }
}
