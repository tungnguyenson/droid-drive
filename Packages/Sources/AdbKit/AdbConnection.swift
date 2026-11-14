import DroidCore
import Foundation

/// Carries whole ADB packets. TCP frames them in one byte stream; USB (UsbKit, later)
/// sends header and payload as separate bulk transfers.
public protocol AdbPacketLink: Sendable {
    func send(_ message: AdbMessage) async throws
    /// Called once the peer's version is known; true means peers check checksums.
    func setChecksumRequired(_ required: Bool) async
    /// Next packet; throws `disconnected` when the link drops.
    func receive() async throws -> AdbMessage
    func close() async
}

/// ADB packets over a TCP stream.
public actor TcpPacketLink: AdbPacketLink {
    private let stream: TcpStream
    private var decoder = AdbMessageDecoder()
    private var checksumRequired = true

    public init(stream: TcpStream) { self.stream = stream }

    public static func connect(host: String, port: UInt16) async throws -> TcpPacketLink {
        TcpPacketLink(stream: try await TcpStream.connect(host: host, port: port))
    }

    public func send(_ message: AdbMessage) async throws {
        try await stream.write(message.encoded(withChecksum: checksumRequired))
    }

    public func setChecksumRequired(_ required: Bool) { checksumRequired = required }

    public func receive() async throws -> AdbMessage {
        while true {
            if let message = try decoder.next() { return message }
            guard let chunk = try await stream.read() else { throw DeviceError.disconnected }
            decoder.append(chunk)
        }
    }

    public func close() async { await stream.close() }
}

/// A direct ADB session with adbd: CNXN/AUTH handshake, then many logical streams
/// multiplexed over one link (spec §5.4, plan P1-05/P1-06).
///
/// Flow control: one WRTE in flight per stream in each direction. We wait for the
/// device's OKAY before sending the next WRTE, and we OKAY a device WRTE only when the
/// consumer has taken it, so a slow disk throttles the phone instead of filling memory.
public actor AdbConnection: AdbServiceOpener {
    public enum AuthEvent: Sendable {
        /// The device does not know our key; the user must tap "Allow" on the phone.
        case waitingForUserApproval
    }

    public nonisolated let banner: DeviceBanner
    public nonisolated var features: Set<String> { banner.features }
    public nonisolated let maxPayload: Int

    private let link: any AdbPacketLink
    private var streams: [UInt32: StreamState] = [:]
    private var nextLocalId: UInt32 = 1
    private var closed = false
    private var readLoop: Task<Void, Never>?

    private init(link: any AdbPacketLink, banner: DeviceBanner, maxPayload: Int) {
        self.link = link
        self.banner = banner
        self.maxPayload = maxPayload
    }

    static let hostFeatures = [
        "shell_v2", "cmd", "stat_v2", "ls_v2", "fixed_push_mkdir", "apex", "abb",
        "fixed_push_symlink_timestamp", "abb_exec", "remount_shell", "track_app",
    ]

    /// Performs the handshake. If the device has never seen `key`, sends the public key
    /// and waits (up to `approvalTimeout`) for the user to allow it.
    public static func connect(link: any AdbPacketLink, key: AdbKey, keyName: String,
                               approvalTimeout: Duration = .seconds(60),
                               onAuth: @Sendable (AuthEvent) -> Void = { _ in }) async throws -> AdbConnection {
        let banner = Data("host::features=\(hostFeatures.joined(separator: ","))".utf8)
        try await link.send(AdbMessage(.cnxn, AdbMessage.version, AdbMessage.maxPayload, banner))

        var sentSignature = false
        var sentPublicKey = false
        var usedTls = false
        while true {
            let message = try await receive(link, timeout: sentPublicKey ? approvalTimeout : .seconds(10))
            switch message.command {
            case .cnxn:
                await link.setChecksumRequired(message.arg0 < AdbMessage.version)
                let connection = AdbConnection(link: link, banner: DeviceBanner(message.payload),
                                               maxPayload: Int(min(message.arg1, AdbMessage.maxPayload)))
                await connection.startReading()
                return connection
            case .auth where message.arg0 == AuthType.token.rawValue:
                if !sentSignature {
                    sentSignature = true
                    let signature = try key.sign(token: message.payload)
                    try await link.send(AdbMessage(.auth, AuthType.signature.rawValue, 0, signature))
                } else if !sentPublicKey {
                    sentPublicKey = true
                    onAuth(.waitingForUserApproval)
                    try await link.send(AdbMessage(.auth, AuthType.rsaPublicKey.rawValue, 0,
                                                   try key.androidPublicKey(name: keyName)))
                } else {
                    throw DeviceError.permissionDenied(.root)
                }
            case .stls:
                // Wireless debugging (Android 11+): reply STLS, run TLS 1.3 on the same
                // socket with our certificate, then the device sends CNXN over TLS and
                // never AUTH (spec §5.4, plan P3-05). Links that cannot do TLS keep failing.
                guard let tlsLink = link as? any AdbTlsUpgradable, !usedTls else {
                    throw DeviceError.unsupported("The device requires TLS (Wi-Fi pairing)")
                }
                usedTls = true
                try await link.send(AdbMessage(.stls, AdbMessage.stlsVersion, 0))
                try await tlsLink.startTls()
            default:
                throw DeviceError.protocolError("Unexpected packet during handshake: \(message.command)")
            }
        }
    }

    enum AuthType: UInt32 {
        case token = 1, signature = 2, rsaPublicKey = 3
    }

    /// Waits for one packet. On timeout it closes the link, which makes the pending
    /// `receive` throw; a task group would instead wait forever for a receive that does
    /// not react to cancellation (NWConnection's doesn't).
    private static func receive(_ link: any AdbPacketLink, timeout: Duration) async throws -> AdbMessage {
        let timer = Task {
            try await Task.sleep(for: timeout)
            await link.close()
        }
        defer { timer.cancel() }
        do {
            return try await link.receive()
        } catch DeviceError.permissionDenied(let path) {
            // A TLS link reports a phone that rejected our certificate (not paired).
            throw DeviceError.permissionDenied(path)
        } catch {
            throw DeviceError.disconnected
        }
    }

    // MARK: Streams

    public func open(_ service: String) async throws -> any AdbByteStream {
        guard !closed else { throw DeviceError.disconnected }
        let localId = nextLocalId
        nextLocalId &+= 1
        if nextLocalId == 0 { nextLocalId = 1 }
        let state = StreamState()
        streams[localId] = state
        try await link.send(AdbMessage(.open, localId, 0, Data(service.utf8) + Data([0])))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The OKAY (or CLSE) may already have arrived while `send` was suspended.
            if state.remoteId != nil {
                continuation.resume()
            } else if state.isClosed {
                continuation.resume(throwing: DeviceError.protocolError("The device refused service \(service)"))
            } else {
                state.openWaiter = continuation
            }
        }
        return Stream(connection: self, localId: localId)
    }

    public func close() async {
        guard !closed else { return }
        failAll()
        readLoop?.cancel()
        await link.close()
    }

    fileprivate func write(_ localId: UInt32, _ data: Data) async throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            guard let state = streams[localId], !state.isClosed, let remoteId = state.remoteId else {
                throw DeviceError.disconnected
            }
            let end = min(offset + maxPayload, data.endIndex)
            try await link.send(AdbMessage(.wrte, localId, remoteId, Data(data[offset..<end])))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if state.unclaimedAcks > 0 {
                    state.unclaimedAcks -= 1
                    continuation.resume()
                } else if state.isClosed {
                    continuation.resume(throwing: DeviceError.disconnected)
                } else {
                    state.writeWaiter = continuation
                }
            }
            offset = end
        }
    }

    fileprivate func read(_ localId: UInt32) async throws -> Data? {
        guard let state = streams[localId] else { return nil }
        if state.inbox.isEmpty {
            if state.isClosed { return nil }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                state.readWaiter = continuation
            }
        }
        guard !state.inbox.isEmpty else {
            if closed && !state.closedByPeer { throw DeviceError.disconnected }
            return nil
        }
        let chunk = state.inbox.removeFirst()
        if let remoteId = state.remoteId, !state.isClosed {
            try? await link.send(AdbMessage(.okay, localId, remoteId))
        }
        return chunk
    }

    fileprivate func closeStream(_ localId: UInt32) async {
        guard let state = streams.removeValue(forKey: localId) else { return }
        if !state.isClosed, let remoteId = state.remoteId {
            try? await link.send(AdbMessage(.clse, localId, remoteId))
        }
        state.markClosed(error: DeviceError.disconnected)
    }

    // MARK: Read loop

    private func startReading() {
        readLoop = Task { [link] in
            while !Task.isCancelled {
                do {
                    let message = try await link.receive()
                    await self.dispatch(message)
                } catch {
                    self.linkFailed()
                    return
                }
            }
        }
    }

    private func dispatch(_ message: AdbMessage) async {
        // Device → host packets carry (device-side id, our id).
        let remoteId = message.arg0
        let localId = message.arg1
        switch message.command {
        case .okay:
            guard let state = streams[localId] else { return }
            if state.remoteId == nil {
                state.remoteId = remoteId
                state.openWaiter?.resume()
                state.openWaiter = nil
            } else if let waiter = state.writeWaiter {
                state.writeWaiter = nil
                waiter.resume()
            } else {
                state.unclaimedAcks += 1
            }
        case .wrte:
            guard let state = streams[localId] else {
                try? await link.send(AdbMessage(.clse, 0, remoteId))
                return
            }
            state.inbox.append(message.payload)
            state.readWaiter?.resume()
            state.readWaiter = nil
        case .clse:
            guard let state = streams[localId] else { return }
            state.closedByPeer = true
            state.markClosed(error: DeviceError.protocolError("The device closed the stream"))
        default:
            break
        }
    }

    private func linkFailed() {
        failAll()
    }

    private func failAll() {
        closed = true
        for state in streams.values { state.markClosed(error: DeviceError.disconnected) }
    }

    /// Per-stream state, only touched on the connection's actor.
    private final class StreamState {
        var remoteId: UInt32?
        var inbox: [Data] = []
        /// OKAYs that arrived before `write` started waiting for them.
        var unclaimedAcks = 0
        var isClosed = false
        var closedByPeer = false
        var openWaiter: CheckedContinuation<Void, Error>?
        var writeWaiter: CheckedContinuation<Void, Error>?
        var readWaiter: CheckedContinuation<Void, Never>?

        func markClosed(error: Error) {
            isClosed = true
            openWaiter?.resume(throwing: error)
            openWaiter = nil
            writeWaiter?.resume(throwing: error)
            writeWaiter = nil
            readWaiter?.resume()
            readWaiter = nil
        }
    }

    private struct Stream: AdbByteStream {
        let connection: AdbConnection
        let localId: UInt32

        func write(_ data: Data) async throws { try await connection.write(localId, data) }
        func read() async throws -> Data? { try await connection.read(localId) }
        func close() async { await connection.closeStream(localId) }
    }
}
