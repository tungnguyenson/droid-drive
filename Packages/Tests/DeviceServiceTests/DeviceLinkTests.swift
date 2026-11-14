import DroidCore
import Foundation
import Testing
@testable import DeviceService

/// The extension ↔ app link end to end, over a real NSXPCConnection in this process.
@Suite("Device link over XPC")
struct DeviceLinkTests {
    @Test("ping attaches the connection and reports the domain")
    func ping() async throws {
        let pair = LinkedPair()
        #expect(!pair.link.isConnected)
        #expect(try await pair.connect() == "domain-1")
        #expect(pair.link.isConnected)
    }

    @Test("hello returns the phone's identity")
    func hello() async throws {
        let pair = LinkedPair()
        try await pair.connect()
        let transport = try await pair.transport()
        #expect(transport.info.serial == fakeSerial)
        #expect(transport.info.model == "Fake Phone")
    }

    @Test("hello for another phone's serial is refused")
    func helloWrongSerial() async throws {
        let pair = LinkedPair()
        try await pair.connect()
        await #expect(throws: DeviceError.self) {
            _ = try await RemoteDeviceTransport.connect(serial: "OTHER", link: pair.link)
        }
    }

    @Test("a listing of 1,234 entries arrives complete, in batches")
    func listing() async throws {
        let pair = LinkedPair()
        let dir = storageRoot.appending("Many")
        for i in 0..<1234 {
            await pair.provider.fake.seedFile(dir.appending(String(format: "f%05d.txt", i)), contents: Data([1]))
        }
        try await pair.connect()
        let transport = try await pair.transport()
        var batches = 0
        var names: [String] = []
        for try await batch in transport.list(dir) {
            batches += 1
            names += batch.map(\.name)
        }
        #expect(names.count == 1234)
        #expect(Set(names).count == 1234)
        #expect(batches == 3)
        #expect(await pair.host.listingCount == 0)
    }

    @Test("listing a missing folder throws notFound")
    func listingMissing() async throws {
        let pair = LinkedPair()
        try await pair.connect()
        let transport = try await pair.transport()
        let missing = storageRoot.appending("Nope")
        #expect(await expectDeviceError(.notFound(missing)) {
            _ = try await transport.listAll(missing)
        })
    }

    @Test("NFD names from the phone keep their bytes across the link")
    func nfdBytes() async throws {
        let pair = LinkedPair()
        let nfd = "Ảnh cưới Đà Lạt.jpg".decomposedStringWithCanonicalMapping
        let path = storageRoot.appending(exact: nfd)
        await pair.provider.fake.seedFile(path, contents: Data("x".utf8))
        try await pair.connect()
        let transport = try await pair.transport()
        let listed = try await transport.listAll(storageRoot)
        #expect(listed.map { Array($0.name.utf8) } == [Array(nfd.utf8)])
        let entry = try await transport.stat(path)
        #expect(Array(entry.path.string.utf8) == Array(path.string.utf8))
    }

    @Test("read copies the file into the descriptor and reports progress")
    func read() async throws {
        let pair = LinkedPair()
        let path = storageRoot.appending("DCIM/photo.jpg")
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        await pair.provider.fake.seedFile(path, contents: bytes)
        try await pair.connect()
        let transport = try await pair.transport()
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        let progress = Progress()
        try await transport.read(path, to: handle, range: nil, progress: progress)
        try handle.close()
        #expect(try Data(contentsOf: url) == bytes)
        #expect(progress.completedUnitCount == Int64(bytes.count))
        let log = await pair.monitor.log.entries()
        #expect(log.count == 1)
        #expect(log.first?.direction == .download)
        #expect(log.first?.bytes == UInt64(bytes.count))
        #expect(log.first?.result == .succeeded)
    }

    @Test("write sends the file, keeps mtime, and is logged as an upload")
    func write() async throws {
        let pair = LinkedPair()
        try await pair.connect()
        let transport = try await pair.transport()
        let contents = Data("hello from the Mac".utf8)
        let url = try temporaryFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let path = storageRoot.appending("Download/note.txt")
        await pair.provider.fake.seedDirectory(path.parent)
        let entry = try await transport.write(path, from: handle, mtime: mtime, progress: Progress())
        #expect(entry.size == UInt64(contents.count))
        #expect(entry.mtime == mtime)
        #expect(await pair.provider.fake.contents(of: path) == contents)
        let log = await pair.monitor.log.entries()
        #expect(log.first?.direction == .upload)
        #expect(log.first?.path == path.string)
    }

    @Test("mkdir, rename, stat and delete reach the phone")
    func directoryOperations() async throws {
        let pair = LinkedPair()
        try await pair.connect()
        let transport = try await pair.transport()
        let dir = storageRoot.appending("New Folder")
        #expect(try await transport.mkdir(dir).kind == .directory)
        let renamed = storageRoot.appending("Renamed")
        #expect(try await transport.rename(dir, to: renamed).path == renamed)
        #expect(try await transport.stat(renamed).kind == .directory)
        try await transport.delete(renamed, recursive: true)
        #expect(await expectDeviceError(.notFound(renamed)) { _ = try await transport.stat(renamed) })
        #expect(try await transport.storages().first?.root == storageRoot)
    }

    @Test("paths outside the domain's storage are refused", arguments: [
        "/data/local/tmp/x", "/storage/emulated/0/../../../data", "/storage/emulated/01/x",
    ])
    func scope(_ raw: String) async throws {
        let pair = LinkedPair()
        try await pair.connect()
        let transport = try await pair.transport()
        await #expect(throws: DeviceError.self) {
            _ = try await transport.stat(RemotePath(exact: raw))
        }
    }

    @Test("the storage root itself cannot be deleted or renamed")
    func protectRoot() async throws {
        let pair = LinkedPair()
        try await pair.connect()
        let transport = try await pair.transport()
        #expect(await expectDeviceError(.permissionDenied(storageRoot)) {
            try await transport.delete(storageRoot, recursive: true)
        })
        #expect(await expectDeviceError(.permissionDenied(storageRoot)) {
            _ = try await transport.rename(storageRoot, to: storageRoot.appending("x"))
        })
    }

    @Test("a phone that went away reports disconnected and drops the cached transport")
    func disconnected() async throws {
        let pair = LinkedPair()
        try await pair.connect()
        let transport = try await pair.transport()
        await pair.provider.fake.setConnected(false)
        #expect(await expectDeviceError(.disconnected) { _ = try await transport.stat(storageRoot) })
        #expect(pair.provider.invalidated == 1)
    }

    @Test("without the app, calls ask for it once, then fail fast")
    func appNotRunning() async throws {
        let pair = LinkedPair(waitTimeout: .milliseconds(200), failFast: 30)
        #expect(await expectDeviceError(.disconnected) { _ = try await pair.transport() })
        #expect(pair.requestCount == 1)
        let started = Date()
        #expect(await expectDeviceError(.disconnected) { _ = try await pair.transport() })
        #expect(Date().timeIntervalSince(started) < 0.1)
        #expect(pair.requestCount == 1)
        // The app comes back: the link works again at once.
        try await pair.connect()
        #expect(try await pair.transport().info.serial == fakeSerial)
    }

    @Test("the app connecting in answer to the request unblocks the waiting call")
    func connectOnRequest() async throws {
        let pair = LinkedPair(autoConnect: true)
        let transport = try await pair.transport()
        #expect(transport.info.serial == fakeSerial)
        #expect(pair.requestCount == 1)
    }

    @Test("when the app quits, the link asks for it again")
    func appQuit() async throws {
        let pair = LinkedPair(waitTimeout: .milliseconds(200), failFast: 0)
        try await pair.connect()
        _ = try await pair.transport()
        pair.connection?.invalidate()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!pair.link.isConnected)
        #expect(await expectDeviceError(.disconnected) { _ = try await pair.transport() })
        #expect(pair.requestCount == 1)
    }

    @Test("a newer app connection replaces the old one")
    func reconnect() async throws {
        let pair = LinkedPair()
        try await pair.connect()
        let first = pair.connection
        try await pair.connect()
        #expect(pair.connection !== first)
        #expect(try await pair.transport().info.serial == fakeSerial)
        pair.link.reset()
        #expect(!pair.link.isConnected)
    }

    @Test("cancelling a download cancels it in the app and logs it as cancelled")
    func cancelDownload() async throws {
        let slow = SlowTransport()
        let provider = SlowProvider(transport: slow)
        let monitor = TransferMonitor(log: TransferLog(url: nil))
        let host = DeviceHost(scope: HostScope(serial: fakeSerial, root: storageRoot), provider: provider, monitor: monitor)
        let link = HostLink(requestHost: {})
        let listener = DeviceLinkListener(link: link, requirement: nil)
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        _ = try await host.serve(connection)
        let transport = try await RemoteDeviceTransport.connect(serial: fakeSerial, link: link)
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        let task = Task {
            try await transport.read(storageRoot.appending("big.bin"), to: handle, range: nil, progress: Progress())
        }
        while await monitor.activeCount(phoneId: fakeSerial) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        _ = await task.result
        while await monitor.activeCount(phoneId: fakeSerial) > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await monitor.log.entries().first?.result == .cancelled)
        withExtendedLifetime(listener) {}
    }
}

/// A transport whose read never ends until cancelled.
final class SlowTransport: DeviceTransport, @unchecked Sendable {
    let info = DeviceInfo(serial: fakeSerial, manufacturer: "Fake", model: "Slow", androidVersion: nil)
    let changes = AsyncStream<ChangeHint> { $0.finish() }
    func storages() async throws -> [StorageInfo] { [] }
    func list(_ dir: RemotePath) -> AsyncThrowingStream<[RemoteEntry], Error> { AsyncThrowingStream { $0.finish() } }
    func stat(_ path: RemotePath) async throws -> RemoteEntry { throw DeviceError.notFound(path) }
    func read(_ path: RemotePath, to fd: FileHandle, range: Range<UInt64>?, progress: Progress) async throws {
        progress.totalUnitCount = 100
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func write(_ path: RemotePath, from fd: FileHandle, mtime: Date?, progress: Progress) async throws -> RemoteEntry {
        throw DeviceError.unsupported("no")
    }
    func mkdir(_ path: RemotePath) async throws -> RemoteEntry { throw DeviceError.unsupported("no") }
    func delete(_ path: RemotePath, recursive: Bool) async throws {}
    func rename(_ from: RemotePath, to: RemotePath) async throws -> RemoteEntry { throw DeviceError.unsupported("no") }
}

struct SlowProvider: TransportProvider {
    let transport: SlowTransport
    func transport(for phoneId: String) async throws -> any DeviceTransport { transport }
    func invalidate(phoneId: String) async {}
}

@Suite("Host link requests")
struct HostLinkRequestTests {
    @Test("many calls waiting at once ask the app once")
    func oneRequestForManyWaiters() async throws {
        let pair = LinkedPair(waitTimeout: .milliseconds(300), failFast: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try? await pair.transport() } }
        }
        #expect(pair.requestCount == 1)
    }
}
