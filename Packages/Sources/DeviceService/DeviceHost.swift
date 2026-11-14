import DroidCore
import Foundation
import os

private let log = Logger(subsystem: "com.droiddrive.deviceservice", category: "host")

/// What one XPC connection may touch: the phone and storage of one Finder domain.
public struct HostScope: Sendable, Equatable {
    public let serial: String
    public let root: RemotePath

    public init(serial: String, root: RemotePath) {
        self.serial = serial
        self.root = root
    }

    /// Accepts only exact-byte paths at or below the storage root, without `.`/`..`.
    func check(_ raw: String) throws -> RemotePath {
        let path = RemotePath(exact: raw)
        let parts = raw.split(separator: "/")
        guard !parts.contains("."), !parts.contains(".."), path.isDescendant(of: root) else {
            throw DeviceError.permissionDenied(path)
        }
        return path
    }
}

/// The app's side of the device link (spec §5.1): runs the extension's requests on the
/// app's transports. One instance per connection, bound to that domain's `HostScope`.
public final class DeviceHost: NSObject, DeviceHostXPC, @unchecked Sendable {
    static let progressInterval: Duration = .milliseconds(250)

    public let scope: HostScope
    private let provider: any TransportProvider
    private let monitor: TransferMonitor
    private let listings = ListingSessions()
    private let lock = NSLock()
    private var client: (@Sendable () -> DeviceClientXPC?)?

    public init(scope: HostScope, provider: any TransportProvider, monitor: TransferMonitor) {
        self.scope = scope
        self.provider = provider
        self.monitor = monitor
    }

    var listingCount: Int {
        get async { await listings.count }
    }

    /// Where progress updates go (the extension's exported object).
    public func setClient(_ client: @escaping @Sendable () -> DeviceClientXPC?) {
        lock.withLock { self.client = client }
    }

    // MARK: DeviceHostXPC

    public func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task { reply(WireCodec.encode(await self.handle(request))) }
    }

    public func read(_ request: Data, into file: FileHandle, reply: @escaping @Sendable (Data) -> Void) {
        Task {
            defer { try? file.close() }
            reply(WireCodec.encode(await self.reply {
                let req = try WireCodec.decode(ReadRequest.self, from: request)
                let path = try self.scope.check(req.path)
                let range = req.rangeStart.flatMap { start in req.rangeEnd.map { start..<$0 } }
                _ = try await self.transfer(id: req.transferId, path: path, direction: .download) { transport, progress in
                    try await transport.read(path, to: file, range: range, progress: progress)
                    return UInt64(max(0, progress.completedUnitCount))
                }
                return .ok
            }))
        }
    }

    public func write(_ request: Data, from file: FileHandle, reply: @escaping @Sendable (Data) -> Void) {
        Task {
            defer { try? file.close() }
            reply(WireCodec.encode(await self.reply {
                let req = try WireCodec.decode(WriteRequest.self, from: request)
                let path = try self.scope.check(req.path)
                let mtime = req.mtime.map { Date(timeIntervalSince1970: $0) }
                let box = EntryBox()
                _ = try await self.transfer(id: req.transferId, path: path, direction: .upload) { transport, progress in
                    let entry = try await transport.write(path, from: file, mtime: mtime, progress: progress)
                    box.set(entry)
                    return entry.size
                }
                guard let written = box.get() else { throw DeviceError.protocolError("Upload returned no entry") }
                return .entry(WireEntry(written))
            }))
        }
    }

    // MARK: Requests

    func handle(_ data: Data) async -> HostReply {
        await reply {
            switch try WireCodec.decode(HostRequest.self, from: data) {
            case .hello(let serial):
                guard serial == self.scope.serial else {
                    throw DeviceError.protocolError("This connection serves another phone")
                }
                return .info(WireInfo(try await self.transport().info))
            case .storages:
                return .storages(try await self.transport().storages().map(WireStorage.init))
            case .stat(let raw):
                return .entry(WireEntry(try await self.transport().stat(try self.scope.check(raw))))
            case .listStart(let raw):
                let path = try self.scope.check(raw)
                let transport = try await self.transport()
                return .listing(await self.listings.start(transport.list(path)))
            case .listNext(let id):
                let next = try await self.listings.next(id)
                return .batch(next.batch.map(WireEntry.init), done: next.done)
            case .listCancel(let id):
                await self.listings.cancel(id)
                return .ok
            case .mkdir(let raw):
                return .entry(WireEntry(try await self.transport().mkdir(try self.scope.check(raw))))
            case .delete(let raw, let recursive):
                let path = try self.scope.check(raw)
                guard path != self.scope.root else { throw DeviceError.permissionDenied(path) }
                try await self.transport().delete(path, recursive: recursive)
                return .ok
            case .rename(let from, let to):
                let source = try self.scope.check(from)
                let target = try self.scope.check(to)
                guard source != self.scope.root else { throw DeviceError.permissionDenied(source) }
                return .entry(WireEntry(try await self.transport().rename(source, to: target)))
            case .cancelTransfer(let id):
                await self.monitor.cancel(id: id)
                return .ok
            }
        }
    }

    /// Runs `body`, turning thrown errors into `.failure`; a disconnect drops the
    /// cached transport so the next call reconnects.
    private func reply(_ body: () async throws -> HostReply) async -> HostReply {
        do {
            return try await body()
        } catch {
            if case DeviceError.disconnected = error {
                await provider.invalidate(phoneId: scope.serial)
            }
            log.notice("request failed: \(String(describing: error), privacy: .public)")
            return .failure(WireError(error))
        }
    }

    private func transport() async throws -> any DeviceTransport {
        try await provider.transport(for: scope.serial)
    }

    /// Runs one upload or download as transfer `id`: logged by the monitor, cancellable
    /// with `cancelTransfer`, progress forwarded to the extension.
    private func transfer(id: String, path: RemotePath, direction: TransferDirection,
                          _ body: @escaping @Sendable (any DeviceTransport, Progress) async throws -> UInt64)
        async throws -> UInt64 {
        let transport = try await transport()
        let progress = Progress(totalUnitCount: 0)
        let work = Task { try await body(transport, progress) }
        let reporter = Task { [weak self] in
            var last: (Int64, Int64) = (-1, -1)
            while !Task.isCancelled {
                let now = (progress.completedUnitCount, progress.totalUnitCount)
                if now != last {
                    last = now
                    await self?.report(id: id, completed: now.0, total: now.1)
                }
                try? await Task.sleep(for: Self.progressInterval)
            }
        }
        defer { reporter.cancel() }
        // Same spelling as the menu ("sdk gphone64 x86 64"), which DeviceDirectory derives.
        let deviceName = transport.info.model.replacingOccurrences(of: "_", with: " ")
        let bytes = try await monitor.run(id: id, phoneId: scope.serial, deviceName: deviceName,
                                          path: path.string, direction: direction,
                                          cancel: { work.cancel() }) {
            try await work.value
        }
        await report(id: id, completed: progress.completedUnitCount, total: progress.totalUnitCount)
        return bytes
    }

    private func report(id: String, completed: Int64, total: Int64) async {
        await monitor.progress(id: id, completed: completed, total: total)
        lock.withLock { client }?()?.transferProgress(id, completed: completed, total: total)
    }
}

/// Carries the uploaded entry out of the `@Sendable` transfer body.
private final class EntryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: RemoteEntry?
    func set(_ value: RemoteEntry) { lock.withLock { entry = value } }
    func get() -> RemoteEntry? { lock.withLock { entry } }
}

public extension DeviceHost {
    /// Serves this host on `connection` (one the app opened to the extension's service
    /// source), routes progress back over it, and pings the extension so it accepts the
    /// connection. Returns the domain identifier the extension reports.
    func serve(_ connection: NSXPCConnection) async throws -> String {
        connection.exportedInterface = NSXPCInterface(with: DeviceHostXPC.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: DeviceClientXPC.self)
        let weak = WeakConnection(connection)
        setClient { weak.value?.remoteObjectProxy as? DeviceClientXPC }
        connection.resume()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(throwing: DeviceError.disconnected) }
            guard let client = proxy as? DeviceClientXPC else {
                once.resume(throwing: DeviceError.disconnected)
                return
            }
            client.ping { once.resume(returning: $0) }
        }
    }
}

/// Lets a `@Sendable` closure reach the connection without keeping it alive.
private final class WeakConnection: @unchecked Sendable {
    weak var value: NSXPCConnection?
    init(_ value: NSXPCConnection) { self.value = value }
}

