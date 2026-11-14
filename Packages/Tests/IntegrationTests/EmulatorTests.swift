import DroidCore
import Foundation
import Testing
@testable import AdbKit

/// Runs AdbTransport against a real adbd (plan P1-09). Opt-in, because it needs a
/// device: set DROIDDRIVE_ADB_SERIAL to go through the local adb server, or
/// DROIDDRIVE_ADB_DIRECT=host:port to talk to adbd directly (emulator: 127.0.0.1:5555,
/// with the adb server stopped). Uses ~/.android/adbkey, which the emulator trusts.
///
///     DROIDDRIVE_ADB_SERIAL=emulator-5554 swift test --filter IntegrationTests
///     DROIDDRIVE_ADB_SERIAL=<phone> DROIDDRIVE_TEST_ROOT=/storage/emulated/0/DroidDriveTest swift test --filter IntegrationTests
enum Device {
    static let serial = ProcessInfo.processInfo.environment["DROIDDRIVE_ADB_SERIAL"]
    static let direct = ProcessInfo.processInfo.environment["DROIDDRIVE_ADB_DIRECT"]
    static var configured: Bool { serial != nil || direct != nil }
    /// Folder the tests work in, one subfolder per test, removed afterwards. Set it to
    /// keep tests on a real phone inside a folder of their own.
    static let root = RemotePath(ProcessInfo.processInfo.environment["DROIDDRIVE_TEST_ROOT"] ?? "/storage/emulated/0/Download")

    static func transport() async throws -> AdbTransport {
        if let direct, let colon = direct.lastIndex(of: ":"), let port = UInt16(direct[direct.index(after: colon)...]) {
            let link = try await TcpPacketLink.connect(host: String(direct[..<colon]), port: port)
            let pem = try String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".android/adbkey"), encoding: .utf8)
            let connection = try await AdbConnection.connect(link: link, key: try AdbKey(pem: pem), keyName: "droiddrive-test")
            return try await AdbTransport.connect(connection)
        }
        let opener = try await AdbServerClient().opener(serial: serial!)
        return try await AdbTransport.connect(opener, fallbackSerial: serial!)
    }
}

@Suite("AdbTransport on a device", .enabled(if: Device.configured), .serialized)
struct EmulatorTests {
    let transport: AdbTransport
    let base: RemotePath

    init() async throws {
        transport = try await Device.transport()
        base = Device.root.appending("droiddrive-test-\(UUID().uuidString.prefix(8))")
        _ = try await transport.mkdir(base)
    }

    // Swift Testing has no async deinit; each test cleans up through this.
    private func cleanup() async {
        try? await transport.delete(base, recursive: true)
    }

    @Test("storages include internal storage with sane sizes")
    func storages() async throws {
        let storages = try await transport.storages()
        let internalStorage = try #require(storages.first { $0.kind == .internal })
        #expect(internalStorage.root == RemotePath("/storage/emulated/0"))
        #expect(internalStorage.capacity > internalStorage.free)
        #expect(internalStorage.free > 0)
        await cleanup()
    }

    @Test("FR-08: an NFD name from the Mac lands as NFC, and there is one file, not two")
    func vietnameseNames() async throws {
        let nfc = "Ảnh cưới Đà Lạt.jpg".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        _ = try await push(base.appending(nfd), Data("một".utf8))
        _ = try await push(base.appending(nfc), Data("hai".utf8))
        let entries = try await transport.listAll(base)
        #expect(entries.count == 1)
        #expect(Array(try #require(entries.first).name.utf8) == Array(nfc.utf8))
        #expect(try await pull(base.appending(nfc)) == Data("hai".utf8))
        await cleanup()
    }

    @Test("FR-09: push keeps the Mac file's mtime")
    func mtime() async throws {
        let when = Date(timeIntervalSince1970: 1_577_953_845)
        let entry = try await push(base.appending("old.txt"), Data("x".utf8), mtime: when)
        #expect(entry.mtime == when)
        #expect(try await transport.stat(base.appending("old.txt")).mtime == when)
        await cleanup()
    }

    @Test("malicious names are created, renamed and deleted as literal names")
    func maliciousNames() async throws {
        // A sentinel next to the test folder: if any name ran as `rm -rf`, it disappears.
        let sentinel = base.appending("sentinel.txt")
        _ = try await push(sentinel, Data("still here".utf8))
        let names = try Data(contentsOf: Bundle.module.url(forResource: "malicious-names", withExtension: "bin")!)
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            .filter { (try? FileName.validate($0)) != nil }
        #expect(names.count >= 10)
        let dir = try await transport.mkdir(base.appending("evil")).path
        for name in names {
            let path = dir.appending(name)
            _ = try await push(path, Data(name.utf8))
            let renamed = try await transport.rename(path, to: dir.appending(name + ".moved"))
            #expect(try await pull(renamed.path) == Data(name.utf8), "\(name.debugDescription)")
            let folder = try await transport.mkdir(dir.appending(name + ".d"))
            try await transport.delete(folder.path, recursive: true)
        }
        let listed = Set(try await transport.listAll(dir).map(\.name))
        #expect(listed == Set(names.map { $0 + ".moved" }))
        #expect(try await pull(sentinel) == Data("still here".utf8))
        await cleanup()
    }

    @Test("rename never overwrites; mkdir over a file is `exists`; missing paths are `notFound`")
    func errors() async throws {
        _ = try await push(base.appending("a.txt"), Data("a".utf8))
        _ = try await push(base.appending("b.txt"), Data("b".utf8))
        await #expect(throws: DeviceError.exists(base.appending("b.txt"))) {
            _ = try await transport.rename(base.appending("a.txt"), to: base.appending("b.txt"))
        }
        #expect(try await pull(base.appending("b.txt")) == Data("b".utf8))
        await #expect(throws: DeviceError.exists(base.appending("a.txt"))) {
            _ = try await transport.mkdir(base.appending("a.txt"))
        }
        await #expect(throws: DeviceError.notFound(base.appending("nope"))) {
            _ = try await transport.stat(base.appending("nope"))
        }
        await #expect(throws: DeviceError.notFound(base.appending("nope"))) {
            _ = try await transport.listAll(base.appending("nope"))
        }
        await cleanup()
    }

    @Test("move a directory with contents")
    func moveDirectory() async throws {
        _ = try await push(base.appending("src/inner/f.txt"), Data("f".utf8))
        _ = try await transport.mkdir(base.appending("dst"))
        _ = try await transport.rename(base.appending("src"), to: base.appending("dst/src"))
        #expect(try await pull(base.appending("dst/src/inner/f.txt")) == Data("f".utf8))
        await cleanup()
    }

    @Test("FR-04: a 10,000-file directory lists completely, first page fast")
    func largeDirectory() async throws {
        let dir = try await transport.mkdir(base.appending("many")).path
        let create = try await transport.shell("cd -- \(ShellQuote.quote(dir)) && seq -f 'file-%05g.txt' 1 10000 | xargs touch")
        #expect(create.exitCode == 0, "\(create.stderrText)")
        let clock = ContinuousClock()
        let start = clock.now
        var firstPage: Duration?
        var total = 0
        var batches = 0
        for try await batch in transport.list(dir) {
            if firstPage == nil { firstPage = clock.now - start }
            total += batch.count
            batches += 1
        }
        let elapsed = clock.now - start
        #expect(total == 10_000)
        #expect(batches == 20)
        #expect(try #require(firstPage) < .seconds(2))
        #expect(elapsed < .seconds(15))
        print("10,000 files: first page \(firstPage!), all \(elapsed)")
        await cleanup()
    }

    // MARK: Helpers

    @discardableResult
    private func push(_ path: RemotePath, _ data: Data, mtime: Date? = nil) async throws -> RemoteEntry {
        if path.parent != base { _ = try await transport.mkdir(path.parent) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try await transport.write(path, from: handle, mtime: mtime, progress: Progress())
    }

    private func pull(_ path: RemotePath) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try await transport.read(path, to: handle, range: nil, progress: Progress())
        try handle.close()
        return try Data(contentsOf: url)
    }
}

/// Old devices (Android < 9/11) lack ls_v2, stat_v2 and shell_v2. Hiding those features
/// from a modern device exercises the v1 code paths: LIST/STAT, and the exit-code marker
/// on plain `shell:`.
@Suite("AdbTransport with v1 protocols", .enabled(if: Device.serial != nil))
struct LegacyProtocolTests {
    @Test("list, stat, push, pull, rename and delete without v2 features")
    func legacy() async throws {
        let modern = try await AdbServerClient().opener(serial: Device.serial!)
        let opener = AdbServerClient.ServerOpener(client: modern.client, serial: modern.serial,
                                                  features: modern.features.subtracting(["ls_v2", "stat_v2", "shell_v2"]))
        let transport = try await AdbTransport.connect(opener, fallbackSerial: Device.serial!)
        #expect(!transport.info.model.isEmpty)
        let base = try await transport.mkdir(Device.root.appending("droiddrive-v1-\(UUID().uuidString.prefix(8))")).path

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("v1 payload".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        let written = try await transport.write(base.appending("a.txt"), from: handle, mtime: Date(timeIntervalSince1970: 1_600_000_000), progress: Progress())
        try handle.close()
        #expect(written.size == 10)
        #expect(written.mtime == Date(timeIntervalSince1970: 1_600_000_000))

        let listed = try await transport.listAll(base)
        #expect(listed.map(\.name) == ["a.txt"])
        #expect(listed.first?.size == 10)

        let renamed = try await transport.rename(base.appending("a.txt"), to: base.appending("b.txt"))
        await #expect(throws: DeviceError.notFound(base.appending("a.txt"))) { _ = try await transport.stat(base.appending("a.txt")) }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        let sink = try FileHandle(forWritingTo: out)
        try await transport.read(renamed.path, to: sink, range: nil, progress: Progress())
        try sink.close()
        #expect(try Data(contentsOf: out) == Data("v1 payload".utf8))

        let failing = try await transport.shell("echo oops >&2; exit 3")
        #expect(failing.exitCode == 3)

        try await transport.delete(base, recursive: true)
        await #expect(throws: DeviceError.notFound(base)) { _ = try await transport.stat(base) }
    }
}
