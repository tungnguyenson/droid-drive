import DroidCore
import Foundation

/// `DeviceTransport` for the File Provider extension: every call goes to the app over
/// the device link, which runs it on the app's own transport (spec §5.1). File contents
/// pass as file descriptors, never inside messages.
public final class RemoteDeviceTransport: DeviceTransport, @unchecked Sendable {
    public let info: DeviceInfo
    /// The app turns device events into `signalEnumerator`; nothing reaches the extension.
    public let changes = AsyncStream<ChangeHint> { $0.finish() }
    private let link: HostLink

    init(info: DeviceInfo, link: HostLink) {
        self.info = info
        self.link = link
    }

    /// Asks the app for the phone `serial` and returns a transport bound to it. Throws
    /// `disconnected` when the app is not running or the phone is not connected.
    public static func connect(serial: String, link: HostLink) async throws -> RemoteDeviceTransport {
        guard case .info(let wire) = try await link.call({ host, reply in
            host.perform(WireCodec.encode(HostRequest.hello(serial: serial)), reply: reply)
        }) else { throw unexpected }
        let info = wire.info
        // Never write to a phone other than the one the drive belongs to (spec §5.4).
        guard info.serial == serial else { throw DeviceError.disconnected }
        return RemoteDeviceTransport(info: info, link: link)
    }

    public func storages() async throws -> [StorageInfo] {
        guard case .storages(let list) = try await perform(.storages) else { throw Self.unexpected }
        return list.map(\.storage)
    }

    public func list(_ dir: RemotePath) -> AsyncThrowingStream<[RemoteEntry], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var listing: String?
                do {
                    guard case .listing(let id) = try await self.perform(.listStart(path: dir.string)) else {
                        throw Self.unexpected
                    }
                    listing = id
                    while true {
                        try Task.checkCancellation()
                        guard case .batch(let entries, let done) = try await self.perform(.listNext(listing: id)) else {
                            throw Self.unexpected
                        }
                        if !entries.isEmpty { continuation.yield(entries.map(\.entry)) }
                        if done { break }
                    }
                    continuation.finish()
                } catch {
                    if let listing, error is CancellationError {
                        _ = try? await self.perform(.listCancel(listing: listing))
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteEntry {
        try await entry(.stat(path: path.string))
    }

    public func read(_ path: RemotePath, to fd: FileHandle, range: Range<UInt64>?, progress: Progress) async throws {
        let request = ReadRequest(transferId: UUID().uuidString, path: path.string,
                                  rangeStart: range?.lowerBound, rangeEnd: range?.upperBound)
        _ = try await transfer(request.transferId, progress) { host, reply in
            host.read(WireCodec.encode(request), into: fd, reply: reply)
        }
    }

    public func write(_ path: RemotePath, from fd: FileHandle, mtime: Date?, progress: Progress) async throws -> RemoteEntry {
        let request = WriteRequest(transferId: UUID().uuidString, path: path.string,
                                   mtime: mtime?.timeIntervalSince1970)
        guard case .entry(let wire) = try await transfer(request.transferId, progress, { host, reply in
            host.write(WireCodec.encode(request), from: fd, reply: reply)
        }) else { throw Self.unexpected }
        return wire.entry
    }

    public func mkdir(_ path: RemotePath) async throws -> RemoteEntry {
        try await entry(.mkdir(path: path.string))
    }

    public func delete(_ path: RemotePath, recursive: Bool) async throws {
        _ = try await perform(.delete(path: path.string, recursive: recursive))
    }

    public func rename(_ from: RemotePath, to: RemotePath) async throws -> RemoteEntry {
        try await entry(.rename(from: from.string, to: to.string))
    }

    // MARK: Helpers

    private static var unexpected: DeviceError { .protocolError("Unexpected reply from DroidDrive") }

    private func perform(_ request: HostRequest) async throws -> HostReply {
        let data = WireCodec.encode(request)
        return try await link.call { host, reply in host.perform(data, reply: reply) }
    }

    private func entry(_ request: HostRequest) async throws -> RemoteEntry {
        guard case .entry(let wire) = try await perform(request) else { throw Self.unexpected }
        return wire.entry
    }

    /// Sends a transfer; cancelling the calling task asks the app to stop it.
    private func transfer(_ id: String, _ progress: Progress,
                          _ send: @escaping @Sendable (DeviceHostXPC, @escaping @Sendable (Data) -> Void) -> Void)
        async throws -> HostReply {
        link.progress.register(id, progress)
        defer { link.progress.unregister(id) }
        let link = link
        return try await withTaskCancellationHandler {
            try await link.call(send)
        } onCancel: {
            Task { _ = try? await link.call { host, reply in
                host.perform(WireCodec.encode(HostRequest.cancelTransfer(id: id)), reply: reply)
            } }
        }
    }
}
