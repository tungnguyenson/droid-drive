import Foundation
import Testing
@testable import DroidCore

@Suite("RemotePath")
struct RemotePathTests {
    @Test("normalizes slashes and keeps an absolute form")
    func normalizes() {
        #expect(RemotePath("//sdcard///DCIM/").string == "/sdcard/DCIM")
        #expect(RemotePath("").string == "/")
        #expect(RemotePath("sdcard").string == "/sdcard")
    }

    @Test("converts NFD input to NFC")
    func nfc() {
        // Swift's String == treats canonically equivalent strings as equal, so compare
        // the bytes that would go over the wire.
        let nfc = "/sdcard/Đà Lạt.jpg".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(Array(nfd.utf8) != Array(nfc.utf8))
        #expect(Array(RemotePath(nfd).string.utf8) == Array(nfc.utf8))
    }

    @Test("name, parent and appending")
    func components() {
        let path = RemotePath("/storage/emulated/0/DCIM")
        #expect(path.name == "DCIM")
        #expect(path.parent == RemotePath("/storage/emulated/0"))
        #expect(RemotePath("/a").parent == .root)
        #expect(RemotePath.root.parent == .root)
        #expect(RemotePath.root.name == "")
        #expect(RemotePath.root.appending("a") == RemotePath("/a"))
        #expect(path.appending("x.jpg").string == "/storage/emulated/0/DCIM/x.jpg")
    }

    @Test("descendant check does not match sibling prefixes")
    func descendant() {
        let dir = RemotePath("/sdcard/Photos")
        #expect(RemotePath("/sdcard/Photos/a.jpg").isDescendant(of: dir))
        #expect(dir.isDescendant(of: dir))
        #expect(!RemotePath("/sdcard/Photos2/a.jpg").isDescendant(of: dir))
        #expect(RemotePath("/x").isDescendant(of: .root))
    }

    @Test("rebases a subtree")
    func replacingPrefix() {
        let old = RemotePath("/sdcard/A")
        let new = RemotePath("/sdcard/B/C")
        #expect(RemotePath("/sdcard/A/x/y").replacingPrefix(old, with: new) == RemotePath("/sdcard/B/C/x/y"))
        #expect(old.replacingPrefix(old, with: new) == new)
        #expect(RemotePath("/sdcard/AB").replacingPrefix(old, with: new) == RemotePath("/sdcard/AB"))
    }
}

@Suite("FileName")
struct FileNameTests {
    @Test("accepts Vietnamese names and returns NFC", arguments: [
        "Ảnh cưới Đà Lạt.jpg", "Ảnh cưới Đà Lạt.jpg".decomposedStringWithCanonicalMapping, ".nomedia", "a b", "日本.txt",
    ])
    func accepts(name: String) throws {
        let result = try FileName.validate(name)
        #expect(Array(result.utf8) == Array(name.precomposedStringWithCanonicalMapping.utf8))
    }

    @Test("rejects every character Android forbids", arguments: Array(FileName.forbiddenCharacters))
    func rejectsForbidden(char: Character) {
        #expect(throws: DeviceError.self) { try FileName.validate("a\(char)b.txt") }
    }

    @Test("rejects empty, dot, dot-dot, control characters, too long", arguments: [
        "", ".", "..", "a\u{0}b", "line\nbreak", String(repeating: "x", count: 256),
    ])
    func rejectsInvalid(name: String) {
        #expect(throws: DeviceError.self) { try FileName.validate(name) }
    }

    @Test("NFD and NFC forms are the same file")
    func same() {
        let nfc = "Đà Lạt.jpg".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(FileName.same(nfc, nfd))
        #expect(!FileName.same(nfc, "Da Lat.jpg"))
    }

    @Test("conflict names keep the extension", arguments: [
        ("Báo cáo.pdf", "Báo cáo (Mac copy).pdf"),
        ("README", "README (Mac copy)"),
        (".bashrc", ".bashrc (Mac copy)"),
        ("archive.tar.gz", "archive.tar (Mac copy).gz"),
    ])
    func conflictName(input: String, expected: String) {
        #expect(FileName.conflictName(for: input) == expected)
    }
}

@Suite("Conflict name attempts")
struct ConflictAttemptTests {
    @Test("later attempts are numbered")
    func numbered() {
        #expect(FileName.conflictName(for: "a.txt", attempt: 2) == "a (Mac copy 2).txt")
        #expect(FileName.conflictName(for: "a.txt", attempt: 1) == FileName.conflictName(for: "a.txt"))
    }
}

@Suite("RemoteEntry and StorageInfo")
struct ModelTests {
    @Test("version combines size and whole-second mtime")
    func version() {
        let a = RemoteEntry(path: RemotePath("/a"), kind: .file, size: 10, mtime: Date(timeIntervalSince1970: 100.7))
        let b = RemoteEntry(path: RemotePath("/b"), kind: .file, size: 10, mtime: Date(timeIntervalSince1970: 100.2))
        #expect(a.version == "10-100")
        #expect(a.version == b.version)
    }

    @Test("display name follows FR-03")
    func displayName() {
        let internalStorage = StorageInfo(id: "/storage/emulated/0", kind: .internal,
                                          root: RemotePath("/storage/emulated/0"), capacity: 1, free: 1)
        let sd = StorageInfo(id: "/storage/1A2B-3C4D", kind: .removable,
                             root: RemotePath("/storage/1A2B-3C4D"), capacity: 1, free: 1)
        #expect(internalStorage.displayName(model: "Pixel 8") == "Pixel 8 · Internal storage")
        #expect(sd.displayName(model: "Pixel 8") == "Pixel 8 · SD card 1A2B-3C4D")
    }
}

@Suite("FakeTransport")
struct FakeTransportTests {
    let transport = FakeTransport(batchSize: 2)
    let root = RemotePath("/storage/emulated/0")

    @Test("write, list in batches, read back")
    func roundTrip() async throws {
        for name in ["a.txt", "b.txt", "c.txt"] {
            try await write(root.appending(name), "hello \(name)")
        }
        var batches: [[RemoteEntry]] = []
        for try await batch in transport.list(root) { batches.append(batch) }
        #expect(batches.map(\.count) == [2, 1])
        #expect(try await read(root.appending("b.txt")) == "hello b.txt")
    }

    @Test("rename never overwrites and moves a subtree")
    func rename() async throws {
        try await write(root.appending("x/1.txt"), "1")
        _ = try await transport.mkdir(root.appending("x"))
        try await write(root.appending("y.txt"), "y")
        await #expect(throws: DeviceError.exists(root.appending("y.txt"))) {
            _ = try await transport.rename(root.appending("x"), to: root.appending("y.txt"))
        }
        _ = try await transport.rename(root.appending("x"), to: root.appending("z"))
        #expect(try await read(root.appending("z/1.txt")) == "1")
        await #expect(throws: DeviceError.notFound(root.appending("x"))) {
            _ = try await transport.stat(root.appending("x"))
        }
    }

    @Test("disconnect makes every call fail with disconnected")
    func disconnect() async throws {
        await transport.setConnected(false)
        await #expect(throws: DeviceError.disconnected) { _ = try await transport.storages() }
        await #expect(throws: DeviceError.disconnected) { _ = try await transport.listAll(root) }
        await transport.setConnected(true)
        #expect(try await transport.listAll(root).isEmpty)
    }

    @Test("delete refuses a non-empty directory unless recursive")
    func delete() async throws {
        try await write(root.appending("d/f.txt"), "f")
        await #expect(throws: DeviceError.self) { try await transport.delete(root.appending("d"), recursive: false) }
        try await transport.delete(root.appending("d"), recursive: true)
        #expect(try await transport.listAll(root).isEmpty)
    }

    private func write(_ path: RemotePath, _ text: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if path.parent != root { _ = try await transport.mkdir(path.parent) }
        _ = try await transport.write(path, from: handle, mtime: nil, progress: Progress())
    }

    private func read(_ path: RemotePath) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try await transport.read(path, to: handle, range: nil, progress: Progress())
        try handle.close()
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite("RemotePath byte preservation")
struct RemotePathExactTests {
    @Test("names from the device keep their NFD bytes, Mac names become NFC")
    func exact() {
        let nfd = "Đà Lạt".decomposedStringWithCanonicalMapping
        let parent = RemotePath("/sdcard").appending(exact: nfd)
        #expect(Array(parent.name.utf8) == Array(nfd.utf8))
        let child = parent.appending("ảnh.jpg".decomposedStringWithCanonicalMapping)
        #expect(Array(child.parent.string.utf8) == Array(parent.string.utf8))
        #expect(Array(child.name.utf8) == Array("ảnh.jpg".precomposedStringWithCanonicalMapping.utf8))
    }
}

@Suite("DomainIdentifier")
struct DomainIdentifierTests {
    @Test("round-trips serials with colons and dots", arguments: ["emulator-5554", "192.168.1.5:5555", "R5CT.1/x"])
    func roundTrip(serial: String) throws {
        let id = DomainIdentifier(serial: serial, storage: "1A2B-3C4D")
        #expect(!id.rawValue.contains("/") && !id.rawValue.contains(":"))
        #expect(DomainIdentifier(rawValue: id.rawValue) == id)
    }

    @Test("maps storages to roots")
    func roots() {
        let internalStorage = StorageInfo(id: "/storage/emulated/0", kind: .internal, root: RemotePath("/storage/emulated/0"), capacity: 1, free: 1)
        let sd = StorageInfo(id: "/storage/1A2B-3C4D", kind: .removable, root: RemotePath("/storage/1A2B-3C4D"), capacity: 1, free: 1)
        #expect(DomainIdentifier(serial: "s", storage: internalStorage).root == internalStorage.root)
        #expect(DomainIdentifier(serial: "s", storage: sd).root == sd.root)
    }

    @Test("rejects malformed raw values", arguments: ["", "nodot", "abc.", "!!!.internal", "YQ.a/b"])
    func rejects(raw: String) {
        #expect(DomainIdentifier(rawValue: raw) == nil)
    }
}
