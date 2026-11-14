import DroidCore
import Foundation
import os

private let log = Logger(subsystem: "com.droiddrive.deviceservice", category: "link")

/// The extension's side of the device link: the connection the app opened to this
/// domain's service source, waited for on demand.
///
/// The extension cannot reach the app by itself (a sandboxed app cannot publish a Mach
/// service). So when it needs the device and has no connection, it calls `requestHost`
/// (the File Provider extension posts a Darwin notification) and waits up to
/// `waitTimeout` for the app to connect. If the app is not running, calls fail with
/// `DeviceError.disconnected`, which the extension reports as `serverUnreachable`;
/// macOS keeps edits queued until the app signals the domain again (FR-10).
public final class HostLink: @unchecked Sendable {
    public static let defaultWaitTimeout: Duration = .seconds(4)
    /// After a wait that timed out, calls fail at once for this long instead of each
    /// waiting again (an enumeration makes many calls).
    public static let defaultFailFastWindow: TimeInterval = 10

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var failedUntil: Date?
    private let requestHost: @Sendable () -> Void
    private let waitTimeout: Duration
    private let failFastWindow: TimeInterval
    let progress = ProgressRouter()

    public init(domainIdentifier: String = "", waitTimeout: Duration = HostLink.defaultWaitTimeout,
                failFastWindow: TimeInterval = HostLink.defaultFailFastWindow,
                requestHost: @escaping @Sendable () -> Void) {
        progress.domainIdentifier = domainIdentifier
        self.waitTimeout = waitTimeout
        self.failFastWindow = failFastWindow
        self.requestHost = requestHost
    }

    public var isConnected: Bool { lock.withLock { connection != nil } }

    /// Takes a connection the app opened (accepted by `DeviceLinkListener`), replacing
    /// any previous one.
    public func attach(_ newConnection: NSXPCConnection) {
        newConnection.remoteObjectInterface = NSXPCInterface(with: DeviceHostXPC.self)
        newConnection.exportedInterface = NSXPCInterface(with: DeviceClientXPC.self)
        newConnection.exportedObject = progress
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            self?.detach(newConnection)
        }
        newConnection.interruptionHandler = { [weak newConnection] in newConnection?.invalidate() }
        newConnection.resume()
        let (old, resumed) = lock.withLock { () -> (NSXPCConnection?, [CheckedContinuation<Void, Error>]) in
            let old = connection
            connection = newConnection
            failedUntil = nil
            let resumed = Array(waiters.values)
            waiters.removeAll()
            return (old, resumed)
        }
        if let old, old !== newConnection { old.invalidate() }
        resumed.forEach { $0.resume() }
        log.info("app connected")
    }

    /// Drops the connection (the app quit or the link failed).
    public func reset() {
        let old = lock.withLock { () -> NSXPCConnection? in
            defer { connection = nil }
            return connection
        }
        old?.invalidate()
    }

    private func detach(_ dead: NSXPCConnection?) {
        lock.withLock {
            if connection === dead { connection = nil }
        }
        log.info("app connection closed")
    }

    /// The connection, asking the app for one and waiting if there is none.
    func currentConnection() async throws -> NSXPCConnection {
        let now = Date()
        let state = lock.withLock { (connection, failedUntil) }
        if let live = state.0 { return live }
        if let until = state.1, until > now { throw DeviceError.disconnected }

        let id = UUID()
        let timeout = waitTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.expire(id)
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let (ready, first) = lock.withLock { () -> (Bool, Bool) in
                if connection != nil { return (true, false) }
                waiters[id] = continuation
                return (false, waiters.count == 1)
            }
            if ready {
                continuation.resume()
            } else if first {
                // One request per wait, however many calls are waiting.
                requestHost()
            }
        }
        guard let live = lock.withLock({ connection }) else { throw DeviceError.disconnected }
        return live
    }

    private func expire(_ id: UUID) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard let waiter = waiters.removeValue(forKey: id) else { return nil }
            failedUntil = Date().addingTimeInterval(failFastWindow)
            return waiter
        }
        if waiter != nil { log.notice("app did not connect; reporting the phone as unreachable") }
        waiter?.resume(throwing: DeviceError.disconnected)
    }

    /// Sends one message and waits for its reply. A connection that breaks before the
    /// reply arrives yields `DeviceError.disconnected`.
    func call(_ send: @Sendable (DeviceHostXPC, @escaping @Sendable (Data) -> Void) -> Void) async throws -> HostReply {
        let connection = try await currentConnection()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                log.notice("link error: \(String(describing: error), privacy: .public)")
                once.resume(throwing: DeviceError.disconnected)
            }
            guard let host = proxy as? DeviceHostXPC else {
                once.resume(throwing: DeviceError.disconnected)
                return
            }
            send(host) { once.resume(returning: $0) }
        }
        let reply = try WireCodec.decode(HostReply.self, from: data)
        if case .failure(let error) = reply { throw error.error }
        return reply
    }
}

/// Resumes a continuation at most once (reply and error handler may both fire).
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

/// Routes the app's progress callbacks to the `Progress` of the matching transfer.
final class ProgressRouter: NSObject, DeviceClientXPC, @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [String: Progress] = [:]
    var domainIdentifier = ""

    func ping(reply: @escaping @Sendable (String) -> Void) { reply(domainIdentifier) }

    func register(_ id: String, _ progress: Progress) { lock.withLock { targets[id] = progress } }
    func unregister(_ id: String) { lock.withLock { targets[id] = nil } }

    func transferProgress(_ transferId: String, completed: Int64, total: Int64) {
        guard let progress = lock.withLock({ targets[transferId] }) else { return }
        if total > 0 { progress.totalUnitCount = total }
        progress.completedUnitCount = completed
    }
}

/// The extension's anonymous listener behind its `NSFileProviderServiceSource`.
public final class DeviceLinkListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    public let link: HostLink
    private let requirement: String?

    /// `requirement`: code signing requirement the connecting app must meet
    /// (`DeviceLink.hostRequirement`), nil to accept any peer (tests, unsigned builds).
    public init(link: HostLink, requirement: String?) {
        self.link = link
        self.requirement = requirement
        super.init()
        listener.delegate = self
        listener.resume()
    }

    public var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        if let requirement {
            if #available(macOS 13.0, *) {
                newConnection.setCodeSigningRequirement(requirement)
            }
        }
        link.attach(newConnection)
        return true
    }

    deinit {
        listener.invalidate()
    }
}
