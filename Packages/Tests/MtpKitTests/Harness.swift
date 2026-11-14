import CryptoKit
import DroidCore
import Foundation
import Testing
@testable import MtpKit
import UsbKit

/// A fake phone plus an `MtpTransport` attached to it, and file helpers mirroring the
/// ones in `EmulatorTests`.
struct Harness {
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let internalRoot = RemotePath("/storage/emulated/0")

    let device: FakeMtpDevice
    let transport: MtpTransport
    let task: Task<Void, Never>

    static func make(_ profile: FakeMtpDevice.Profile = .android,
                     storages: [UInt32: PtpStorageInfo]? = nil,
                     seed: (FakeMtpDevice) async -> Void = { _ in }) async throws -> Harness {
        let device = FakeMtpDevice(profile: profile, storages: storages)
        await seed(device)
        let task = await device.start()
        let transport = try await MtpTransport.open(channels: device.channels, serial: "USBSERIAL", timeZone: utc)
        return Harness(device: device, transport: transport, task: task)
    }

    func finish() async {
        await transport.close()
        task.cancel()
        let violations = await device.violations
        #expect(violations.isEmpty, "USB/MTP framing violations: \(violations)")
    }

    func path(_ relative: String) -> RemotePath { Self.internalRoot.appending(relative) }

    @discardableResult
    func push(_ path: RemotePath, _ data: Data, mtime: Date? = nil, progress: Progress = Progress()) async throws -> RemoteEntry {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try await transport.write(path, from: handle, mtime: mtime, progress: progress)
    }

    func pull(_ path: RemotePath, range: Range<UInt64>? = nil, progress: Progress = Progress()) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try await transport.read(path, to: handle, range: range, progress: progress)
        try handle.close()
        return try Data(contentsOf: url)
    }

    /// Names from the shared malicious-names fixture that pass `FileName.validate`.
    static func maliciousNames(filePath: String = #filePath) throws -> [String] {
        let tests = URL(fileURLWithPath: filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: tests.appendingPathComponent("IntegrationTests/malicious-names.bin"))
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            .filter { (try? FileName.validate($0)) != nil }
    }
}

/// SHA-256 of a file without loading it.
func sha256(of url: URL) throws -> SHA256.Digest {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize()
}

/// Collects hints from `changes` until `predicate` holds or the timeout passes.
func waitForHint(_ transport: MtpTransport, timeout: Duration = .seconds(5),
                 where predicate: @escaping @Sendable (ChangeHint) -> Bool) async -> ChangeHint? {
    let stream = transport.changes
    return await withTaskGroup(of: ChangeHint?.self) { group in
        group.addTask {
            for await hint in stream where predicate(hint) { return hint }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
