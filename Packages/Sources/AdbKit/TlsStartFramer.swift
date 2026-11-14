import DroidCore
import Foundation
import Network

/// Sits between TLS and TCP in a `TlsChannel.connectStartTls` connection. Until
/// `StartTlsBridge.upgrade()` it keeps the connection "preparing" (so TLS above has
/// not sent its ClientHello yet) and moves plaintext bytes between the socket and the
/// bridge; then it marks itself ready and passes everything through untouched, so the
/// TLS handshake runs on the same socket right after the STLS exchange.
final class StartTlsFramer: NWProtocolFramerImplementation {
    static let label = "DroidDriveStartTLS"
    static let definition = NWProtocolFramer.Definition(implementation: StartTlsFramer.self)
    static let bridgeKey = "droiddrive.bridge"

    private var bridge: StartTlsBridge?

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        guard let bridge = framer.options[Self.bridgeKey] as? StartTlsBridge else { return .ready }
        self.bridge = bridge
        bridge.attach(framer)
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var chunk = Data()
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 1 << 16) { buffer, _ in
                guard let buffer, buffer.count > 0 else { return 0 }
                chunk = Data(buffer)
                return buffer.count
            }
            guard parsed, !chunk.isEmpty else { return 0 }
            bridge?.deliver(chunk)
        }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        // Only reached if TLS writes before the upgrade, which it cannot; pass it on anyway.
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func stop(framer: NWProtocolFramer.Instance) -> Bool {
        bridge?.fail()
        return true
    }

    func cleanup(framer: NWProtocolFramer.Instance) {
        bridge?.fail()
    }
}

/// Shared between a `TlsChannel` and its `StartTlsFramer`: the plaintext inbox before
/// TLS, and the switch that starts TLS. Framer calls arrive on the connection's queue,
/// channel calls from tasks; a lock keeps them in step.
final class StartTlsBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var framer: NWProtocolFramer.Instance?
    private var inbox: [Data] = []
    private var readWaiter: CheckedContinuation<Data?, Error>?
    private var failed = false

    /// Set by the channel before the connection starts.
    var onStarted: (@Sendable () -> Void)?
    var onFailed: (@Sendable () -> Void)?

    func attach(_ framer: NWProtocolFramer.Instance) {
        lock.withLock { self.framer = framer }
        onStarted?()
    }

    func deliver(_ data: Data) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
            if let waiter = readWaiter {
                readWaiter = nil
                return waiter
            }
            inbox.append(data)
            return nil
        }
        waiter?.resume(returning: data)
    }

    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            lock.lock()
            if !inbox.isEmpty {
                let first = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: first)
            } else if failed {
                lock.unlock()
                continuation.resume(throwing: DeviceError.disconnected)
            } else {
                readWaiter = continuation
                lock.unlock()
            }
        }
    }

    func write(_ data: Data) throws {
        guard let framer = lock.withLock({ failed ? nil : self.framer }) else { throw DeviceError.disconnected }
        framer.async { framer.writeOutput(data: data) }
    }

    /// Lets the TLS layer above start its handshake.
    func upgrade() {
        guard let framer = lock.withLock({ self.framer }) else { return }
        framer.async {
            framer.passThroughInput()
            framer.passThroughOutput()
            framer.markReady()
        }
    }

    func fail() {
        let waiter = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
            guard !failed else { return nil }
            failed = true
            defer { readWaiter = nil }
            return readWaiter
        }
        waiter?.resume(throwing: DeviceError.disconnected)
        onFailed?()
    }
}
