import DroidCore
import Foundation
import Network
import os
import Security

/// A TLS 1.3 byte stream for Wi-Fi ADB (spec §5.4), on Network.framework.
///
/// Two ways in:
/// - `connect`: TLS from the first byte. The pairing port works this way (plan P3-03).
/// - `connectStartTls`: plaintext first, TLS later on the same socket. adbd's TLS port
///   answers our CNXN with STLS, and only then do both sides start TLS (plan P3-05).
///   Network.framework cannot add TLS to a running connection, so the connection is
///   built as TLS over `StartTlsFramer` over TCP: the framer holds the TLS layer back
///   (`willMarkReady`) and carries the plaintext packets itself, then steps aside and
///   lets the TLS handshake through.
///
/// Both sides use TLS 1.3 only and accept any peer certificate, like adb: on the
/// pairing port SPAKE2 authenticates, and on the connect port the phone checks our
/// certificate against the keys it paired with.
public final class TlsChannel: AdbByteStream, @unchecked Sendable {
    // NWConnection is internally synchronized; `@unchecked` covers its missing annotation.
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "droiddrive.tls")
    private let bridge: StartTlsBridge?
    private let state = ConnectionWaiter()
    private static let logger = Logger(subsystem: "com.droiddrive", category: "tls")

    private init(connection: NWConnection, bridge: StartTlsBridge?) {
        self.connection = connection
        self.bridge = bridge
    }

    /// TLS from the start, as a client presenting `identity`.
    public static func connect(host: String, port: UInt16, identity: TlsIdentity,
                               timeout: TimeInterval = 10) async throws -> TlsChannel {
        let parameters = NWParameters(tls: tlsOptions(identity: identity, server: false), tcp: tcpOptions(timeout))
        let channel = TlsChannel(connection: NWConnection(host: NWEndpoint.Host(host),
                                                          port: try nwPort(port), using: parameters),
                                 bridge: nil)
        try await channel.start(timeout: timeout, untilFramerStarts: false)
        return channel
    }

    /// Plaintext until `startTls()`.
    public static func connectStartTls(host: String, port: UInt16, identity: TlsIdentity,
                                       timeout: TimeInterval = 10) async throws -> TlsChannel {
        let parameters = NWParameters(tls: tlsOptions(identity: identity, server: false), tcp: tcpOptions(timeout))
        let bridge = StartTlsBridge()
        let framer = NWProtocolFramer.Options(definition: StartTlsFramer.definition)
        framer[StartTlsFramer.bridgeKey] = bridge
        // Application protocols are listed top to bottom; appending puts the framer under TLS.
        parameters.defaultProtocolStack.applicationProtocols.append(framer)
        let channel = TlsChannel(connection: NWConnection(host: NWEndpoint.Host(host),
                                                          port: try nwPort(port), using: parameters),
                                 bridge: bridge)
        try await channel.start(timeout: timeout, untilFramerStarts: true)
        return channel
    }

    /// The server side of a connection an `NWListener` built with `serverParameters` accepted.
    public static func accept(_ connection: NWConnection, timeout: TimeInterval = 10) async throws -> TlsChannel {
        let channel = TlsChannel(connection: connection, bridge: nil)
        try await channel.start(timeout: timeout, untilFramerStarts: false)
        return channel
    }

    /// Parameters for an `NWListener` that serves TLS 1.3 with `identity` and requires a
    /// client certificate (what the phone's pairing server does).
    public static func serverParameters(identity: TlsIdentity) -> NWParameters {
        NWParameters(tls: tlsOptions(identity: identity, server: true), tcp: tcpOptions(10))
    }

    static func tlsOptions(identity: TlsIdentity, server: Bool) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        if let local = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(options, local)
        }
        if server { sec_protocol_options_set_peer_authentication_required(options, true) }
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(true) },
                                              DispatchQueue(label: "droiddrive.tls.verify"))
        return tls
    }

    private static func tcpOptions(_ timeout: TimeInterval) -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        return tcp
    }

    private static func nwPort(_ port: UInt16) throws -> NWEndpoint.Port {
        guard port != 0, let value = NWEndpoint.Port(rawValue: port) else {
            throw DeviceError.protocolError("Invalid port \(port)")
        }
        return value
    }

    private func start(timeout: TimeInterval, untilFramerStarts: Bool) async throws {
        connection.stateUpdateHandler = { [state, connection] newState in
            switch newState {
            case .ready:
                state.ready()
            case .failed(let error):
                state.fail(Self.map(error))
            case .waiting(let error):
                // Refused, unreachable or a failed handshake: NWConnection would retry forever.
                state.fail(Self.map(error))
                connection.cancel()
            case .cancelled:
                state.fail(DeviceError.disconnected)
            default:
                break
            }
        }
        bridge?.onStarted = { [state] in state.framerStarted() }
        bridge?.onFailed = { [state] in state.fail(DeviceError.disconnected) }
        connection.start(queue: queue)
        let timer = Task { [state, connection] in
            try await Task.sleep(for: .seconds(timeout))
            state.fail(DeviceError.disconnected)
            connection.cancel()
        }
        defer { timer.cancel() }
        do {
            if untilFramerStarts {
                try await state.waitFramerStarted()
            } else {
                try await state.waitReady()
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    /// Starts the TLS handshake on a `connectStartTls` channel and waits for it.
    public func startTls(timeout: TimeInterval = 10) async throws {
        guard let bridge else { throw DeviceError.protocolError("This connection already uses TLS") }
        bridge.upgrade()
        let timer = Task { [state, connection] in
            try await Task.sleep(for: .seconds(timeout))
            state.fail(DeviceError.disconnected)
            connection.cancel()
        }
        defer { timer.cancel() }
        try await state.waitReady()
    }

    private var tlsActive: Bool { bridge == nil || state.isReady }

    public func write(_ data: Data) async throws {
        if !tlsActive, let bridge {
            try bridge.write(data)
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Self.map(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func read() async throws -> Data? {
        if !tlsActive, let bridge { return try await bridge.read() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: Self.map(error))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func close() async {
        bridge?.fail()
        connection.cancel()
    }

    /// RFC 8446 §7.5 exporter of the established TLS session (no context).
    public func exportKeyingMaterial(label: Data, length: Int) throws -> Data {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            throw DeviceError.protocolError("TLS is not established")
        }
        let secret = label.withUnsafeBytes { raw in
            sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, raw.count,
                                                raw.bindMemory(to: CChar.self).baseAddress!, length)
        }
        guard let secret else { throw DeviceError.protocolError("Could not export TLS keying material") }
        var out = Data(count: 0)
        (secret as DispatchData).enumerateBytes { buffer, _, _ in out.append(contentsOf: buffer) }
        guard out.count == length else { throw DeviceError.protocolError("Short TLS keying material") }
        return out
    }

    /// TLS alerts that mean "the peer does not accept our certificate" become
    /// `permissionDenied`: for adbd that is "this Mac is not paired (any more)".
    static func map(_ error: NWError) -> Error {
        if case .tls(let status) = error {
            logger.error("TLS failed: \(status)")
            if rejectionStatuses.contains(status) { return DeviceError.permissionDenied(.root) }
        }
        return DeviceError.disconnected
    }

    /// Alerts adbd's BoringSSL sends when its certificate check fails (bad_certificate,
    /// certificate_unknown…), plus TLS 1.3's certificate_required.
    static let rejectionStatuses: Set<OSStatus> = [
        errSSLPeerCertUnknown, errSSLPeerAccessDenied, errSSLPeerBadCert, errSSLPeerUnknownCA,
        errSSLPeerCertRevoked, errSSLPeerCertExpired, errSSLCertificateRequired,
    ]
}

/// Waiters for NWConnection state changes. Callbacks come from the connection queue,
/// waiters from tasks; a lock keeps them in step.
final class ConnectionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var readyState = false
    private var started = false
    private var failure: Error?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var startWaiters: [CheckedContinuation<Void, Error>] = []

    var isReady: Bool { lock.withLock { readyState } }

    func ready() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            readyState = true
            started = true
            defer { readyWaiters = []; startWaiters = [] }
            return readyWaiters + startWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func framerStarted() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            started = true
            defer { startWaiters = [] }
            return startWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func fail(_ error: Error) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            if failure == nil { failure = error }
            defer { readyWaiters = []; startWaiters = [] }
            return readyWaiters + startWaiters
        }
        waiters.forEach { $0.resume(throwing: error) }
    }

    func waitReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if readyState {
                lock.unlock()
                continuation.resume()
            } else if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
            } else {
                readyWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func waitFramerStarted() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
