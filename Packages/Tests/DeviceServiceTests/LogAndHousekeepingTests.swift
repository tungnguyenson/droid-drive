import DroidCore
import Foundation
import Testing
@testable import DeviceService

private func record(_ path: String, phone: String = "P1", direction: TransferDirection = .download,
                    result: TransferResult = .succeeded, at date: Date = Date(), bytes: UInt64 = 1000,
                    duration: TimeInterval = 2) -> TransferRecord {
    TransferRecord(started: date, phoneId: phone, deviceName: "Pixel", path: path, direction: direction,
                   bytes: bytes, duration: duration, result: result)
}

@Suite("Transfer log")
struct TransferLogTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dd-log-\(UUID().uuidString)/transfers.jsonl")

    @Test("records persist across instances, newest first")
    func persistence() async throws {
        let log = TransferLog(url: url)
        await log.append(record("/a.jpg", at: Date().addingTimeInterval(-10)))
        await log.append(record("/b.jpg"))
        let reopened = TransferLog(url: url)
        #expect(await reopened.entries().map(\.path) == ["/b.jpg", "/a.jpg"])
    }

    @Test("records older than 7 days are dropped on load and on prune")
    func retention() async throws {
        let now = Date()
        let log = TransferLog(url: url)
        await log.append(record("/old", at: now.addingTimeInterval(-8 * 86400)))
        await log.append(record("/new", at: now.addingTimeInterval(-86400)))
        #expect(await TransferLog(url: url).entries(now: now).map(\.path) == ["/new"])
        await log.prune(now: now.addingTimeInterval(7 * 86400))
        #expect(await log.entries().isEmpty)
        #expect(await TransferLog(url: url).entries().isEmpty)
    }

    @Test("filter by phone, result, direction and text")
    func filter() async throws {
        let log = TransferLog(url: nil)
        await log.append(record("/DCIM/Ảnh.jpg", phone: "P1"))
        await log.append(record("/Download/x.pdf", phone: "P2", direction: .upload, result: .failed("no space")))
        await log.append(record("/Music/y.mp3", phone: "P1", result: .cancelled))
        #expect(await log.entries(matching: TransferFilter(phoneId: "P1")).count == 2)
        #expect(await log.entries(matching: TransferFilter(result: .failed)).map(\.path) == ["/Download/x.pdf"])
        #expect(await log.entries(matching: TransferFilter(direction: .upload)).count == 1)
        #expect(await log.entries(matching: TransferFilter(text: "anh")).map(\.path) == ["/DCIM/Ảnh.jpg"])
        #expect(await log.entries(matching: TransferFilter(text: "  ")).count == 3)
    }

    @Test("clear empties the file; a torn line is skipped")
    func clearAndCorruption() async throws {
        let log = TransferLog(url: url)
        await log.append(record("/a"))
        var data = try Data(contentsOf: url)
        data.append(Data("{\"broken\n".utf8))
        try data.write(to: url)
        #expect(await TransferLog(url: url).entries().map(\.path) == ["/a"])
        await log.clear()
        #expect(await TransferLog(url: url).entries().isEmpty)
    }

    @Test("reload sees lines another writer appended")
    func reload() async throws {
        let log = TransferLog(url: url)
        #expect(await log.entries().isEmpty)
        await TransferLog(url: url).append(record("/other"))
        await log.reload()
        #expect(await log.entries().map(\.path) == ["/other"])
    }

    @Test("speed and file name")
    func derived() {
        #expect(record("/DCIM/a.jpg", bytes: 1000, duration: 2).bytesPerSecond == 500)
        #expect(record("/a", duration: 0).bytesPerSecond == nil)
        #expect(record("/DCIM/a.jpg").fileName == "a.jpg")
        #expect(TransferResult.failed("x").kind == .failed)
    }
}

@Suite("Transfer monitor")
struct TransferMonitorTests {
    @Test("tracks active transfers, broadcasts events, logs results")
    func lifecycle() async throws {
        let monitor = TransferMonitor(log: TransferLog(url: nil))
        let events = await monitor.events()
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            try await monitor.run(id: "t1", phoneId: "P1", deviceName: "Pixel", path: "/a", direction: .upload,
                                  cancel: {}) {
                for await _ in gate.stream { break }
                return 42
            }
        }
        var iterator = events.makeAsyncIterator()
        guard case .started(let started) = await iterator.next() else { Issue.record("no start"); return }
        #expect(started.id == "t1")
        #expect(await monitor.activeCount(phoneId: "P1") == 1)
        await monitor.progress(id: "t1", completed: 10, total: 42)
        #expect(await monitor.activeTransfers.first?.completed == 10)
        gate.continuation.yield()
        #expect(try await task.value == 42)
        guard case .finished(let done) = await iterator.next() else { Issue.record("no finish"); return }
        #expect(done.bytes == 42)
        #expect(await monitor.activeCount(phoneId: "P1") == 0)
        #expect(await monitor.log.entries().count == 1)
    }

    @Test("failures are logged with the device error's message")
    func failure() async throws {
        let monitor = TransferMonitor(log: TransferLog(url: nil))
        await #expect(throws: DeviceError.self) {
            _ = try await monitor.run(id: "t", phoneId: "P1", deviceName: "Pixel", path: "/a", direction: .upload,
                                      cancel: {}) { throw DeviceError.noSpace(needed: 2_000_000, available: 1000) }
        }
        let result = await monitor.log.entries().first?.result
        guard case .failed(let message) = result else { Issue.record("not failed"); return }
        #expect(message.hasPrefix("Not enough space on the phone"))
    }

    @Test("cancelAll stops every transfer of one phone")
    func cancelAll() async throws {
        let monitor = TransferMonitor(log: TransferLog(url: nil))
        let cancelled = Counter()
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            try await monitor.run(id: "t", phoneId: "P1", deviceName: "Pixel", path: "/a", direction: .download,
                                  cancel: { cancelled.increment(); gate.continuation.finish() }) {
                for await _ in gate.stream {}
                throw CancellationError()
            }
        }
        while await monitor.activeCount(phoneId: "P1") == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await monitor.cancelAll(phoneId: "P2")
        #expect(cancelled.value == 0)
        await monitor.cancelAll(phoneId: "P1")
        _ = await task.result
        #expect(cancelled.value == 1)
        #expect(await monitor.log.entries().first?.result == .cancelled)
    }
}

@Suite("Housekeeping")
struct HousekeepingTests {
    @Test("refresh is due per device interval; off is never due")
    func schedule() {
        var schedule = RefreshSchedule()
        let t0 = Date()
        let phones: [(id: String, interval: RefreshInterval)] = [("A", .tenSeconds), ("B", .oneMinute), ("C", .off)]
        #expect(schedule.due(phones, now: t0) == ["A", "B"])
        schedule.signalled(["A", "B"], at: t0)
        #expect(schedule.due(phones, now: t0.addingTimeInterval(9)).isEmpty)
        #expect(schedule.due(phones, now: t0.addingTimeInterval(10)) == ["A"])
        #expect(schedule.due(phones, now: t0.addingTimeInterval(60)) == ["A", "B"])
        schedule.forget("B")
        #expect(schedule.due(phones, now: t0.addingTimeInterval(1)) == ["B"])
        #expect(RefreshInterval.off.seconds == nil)
        #expect(RefreshInterval.allCases.map(\.label).allSatisfy { !$0.isEmpty })
        #expect(RefreshInterval.default.id == 30)
    }

    @Test("a storage that appears later gets a domain; a vanished one is reported")
    func storagePlan() {
        let internalStorage = StorageInfo(id: "/storage/emulated/0", kind: .internal,
                                          root: RemotePath("/storage/emulated/0"), capacity: 1, free: 1)
        let sd = StorageInfo(id: "/storage/0000-0000", kind: .removable, root: RemotePath("/storage/0000-0000"),
                             capacity: 1, free: 1)
        let mountedInternal = DomainIdentifier(serial: "P1", storage: internalStorage)
        let otherPhone = DomainIdentifier(serial: "P2", storage: "internal")
        let late = StoragePlan.plan(serial: "P1", storages: [internalStorage, sd], mounted: [mountedInternal, otherPhone])
        #expect(late.add == [sd])
        #expect(late.missing.isEmpty)
        let sdDomain = DomainIdentifier(serial: "P1", storage: sd)
        let removed = StoragePlan.plan(serial: "P1", storages: [internalStorage], mounted: [mountedInternal, sdDomain])
        #expect(removed.add.isEmpty)
        #expect(removed.missing == [sdDomain])
    }

    @Test("known devices keep per-device settings across sightings")
    func knownDevices() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var known = KnownDevices().seen(phone("P1", model: "Pixel 8"), androidVersion: "15", at: t0)
        known = known.setting(.fiveMinutes, for: "P1")
        known = known.seen(phone("P1", .adbWiFi, model: "Pixel 8"), androidVersion: nil, at: t0.addingTimeInterval(5))
        #expect(known["P1"]?.refreshInterval == .fiveMinutes)
        #expect(known["P1"]?.androidVersion == "15")
        #expect(known["P1"]?.connection == .adbWiFi)
        #expect(known["P1"]?.lastSeen == t0.addingTimeInterval(5))
        let restored = KnownDevices(data: known.data)
        #expect(restored == known)
        #expect(restored.removing("P1").devices.isEmpty)
        #expect(KnownDevices(data: Data("junk".utf8)).devices.isEmpty)
        #expect(known.setting(.off, for: "nobody") == known)
    }

    @Test("device errors read as sentences")
    func errorText() {
        let path = RemotePath("/storage/emulated/0/a.txt")
        let all: [DeviceError] = [.disconnected, .busy(by: nil), .busy(by: "ptpcamerad"), .notFound(path), .exists(path),
                                  .noSpace(needed: 10, available: 1), .permissionDenied(path), .unsupported("u"),
                                  .invalidName("a:b", reason: "r"), .protocolError("p")]
        #expect(Set(all.map(\.userMessage)).count == all.count)
        #expect(DeviceError.busy(by: "ptpcamerad").userMessage.contains("ptpcamerad"))
    }

    @Test("host requirement names the app and team; empty without a team")
    func requirement() {
        let req = DeviceLink.hostRequirement(appBundleId: "dev.droiddrive.app", teamId: "ABCDE12345")
        #expect(req?.contains("identifier \"dev.droiddrive.app\"") == true)
        #expect(req?.contains("subject.OU] = \"ABCDE12345\"") == true)
        #expect(DeviceLink.hostRequirement(appBundleId: "x", teamId: "") == nil)
        #expect(DeviceLink.linkRequestNotification(appGroup: "G", domainIdentifier: "D") == "G.link-request.D")
    }
}

@Suite("Wire format")
struct WireTests {
    @Test("every device error survives the trip")
    func errors() throws {
        let path = RemotePath(exact: "/storage/emulated/0/x".decomposedStringWithCanonicalMapping)
        let all: [DeviceError] = [.disconnected, .busy(by: "x"), .notFound(path), .exists(path),
                                  .noSpace(needed: 1, available: 0), .permissionDenied(path), .unsupported("u"),
                                  .invalidName("n", reason: "r"), .protocolError("p")]
        for error in all {
            let data = WireCodec.encode(HostReply.failure(WireError(error)))
            guard case .failure(let wire) = try WireCodec.decode(HostReply.self, from: data) else {
                Issue.record("not a failure")
                continue
            }
            #expect(wire.error as? DeviceError == error)
        }
        #expect(WireError(CancellationError()).error is CancellationError)
        guard case .protocolError = WireError(CocoaError(.fileNoSuchFile)) else {
            Issue.record("a foreign error should become protocolError")
            return
        }
    }

    @Test("garbage is a protocol error, not a crash")
    func garbage() {
        #expect(throws: DeviceError.self) { try WireCodec.decode(HostRequest.self, from: Data("nope".utf8)) }
    }

    @Test("storage and info round trip")
    func values() {
        let storage = StorageInfo(id: "/storage/0000-0000", kind: .removable, root: RemotePath("/storage/0000-0000"),
                                  capacity: 5, free: 2)
        #expect(WireStorage(storage).storage == storage)
        let info = DeviceInfo(serial: "S", manufacturer: "M", model: "Mo", androidVersion: nil)
        #expect(WireInfo(info).info == info)
    }
}

@Suite("Listing sessions")
struct ListingSessionTests {
    @Test("an error after some batches arrives after those batches")
    func errorAfterBatches() async throws {
        let sessions = ListingSessions()
        let stream = AsyncThrowingStream<[RemoteEntry], Error> { continuation in
            continuation.yield([RemoteEntry(path: RemotePath("/a"), kind: .file, size: 1, mtime: Date())])
            continuation.finish(throwing: DeviceError.disconnected)
        }
        let id = await sessions.start(stream)
        let first = try await sessions.next(id)
        #expect(first.batch.count == 1)
        #expect(!first.done)
        await #expect(throws: DeviceError.disconnected) { _ = try await sessions.next(id) }
        await #expect(throws: DeviceError.self) { _ = try await sessions.next(id) }
    }

    @Test("an empty folder is one empty, done batch; cancel forgets the session")
    func emptyAndCancel() async throws {
        let sessions = ListingSessions()
        let id = await sessions.start(AsyncThrowingStream { $0.finish() })
        let next = try await sessions.next(id)
        #expect(next.batch.isEmpty && next.done)
        let other = await sessions.start(AsyncThrowingStream { _ in })
        #expect(await sessions.count == 1)
        await sessions.cancel(other)
        #expect(await sessions.count == 0)
    }
}

@Suite("Conflict copies")
struct ConflictCopyTests {
    @Test("names made by FileName.conflictName are recognised", arguments: ["photo.jpg", "notes", ".bashrc", "a.b.c"])
    func roundTrip(_ name: String) {
        #expect(ConflictCopy.matches(FileName.conflictName(for: name)))
        #expect(ConflictCopy.matches(FileName.conflictName(for: name, attempt: 3)))
        #expect(!ConflictCopy.matches(name))
    }

    @Test("look-alikes are not", arguments: ["photo (Mac copy x).jpg", "photo (Mac copy ).jpg", "(Mac copy", "Mac copy).txt"])
    func lookAlikes(_ name: String) {
        #expect(!ConflictCopy.matches(name))
    }
}
