import AdbKit
import DroidCore
import Foundation
import Network
import os

/// The phone's side of pairing, on this Mac. DroidDrive does not need it to pair with
/// phones; it exists so the client can be checked end to end without a phone, against
/// itself and against the real `adb pair` (plan P3-03 test notes).
public final class PairingServer: @unchecked Sendable {
    public struct Paired: Sendable {
        /// What the client sent: for `adb`, `ADB_RSA_PUB_KEY` with `<base64> <user@host>`.
        public let peerInfo: PeerInfo
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "droiddrive.pairing-server")
    private let code: String
    private let guid: String
    private let results: AsyncStream<Result<Paired, Error>>
    private let continuation: AsyncStream<Result<Paired, Error>>.Continuation
    private static let logger = Logger(subsystem: "com.droiddrive", category: "pairing")

    /// Listens on 127.0.0.1 and a free port; `guid` is what we report as our device GUID.
    public init(code: String, guid: String, identity: TlsIdentity) throws {
        self.code = code
        self.guid = guid
        let parameters = TlsChannel.serverParameters(identity: identity)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        (results, continuation) = AsyncStream.makeStream()
    }

    /// Starts listening and returns the port.
    public func start() async throws -> UInt16 {
        let once = Flag()
        return try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard !once.isSet else { return }
                    once.set()
                    ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed, .cancelled:
                    guard !once.isSet else { return }
                    once.set()
                    ready.resume(throwing: DeviceError.disconnected)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.serve(connection) }
            }
            listener.start(queue: queue)
        }
    }

    /// One result per client that connected: what it sent, or why it failed.
    public var pairings: AsyncStream<Result<Paired, Error>> { results }

    public func stop() {
        listener.cancel()
        continuation.finish()
    }

    private func serve(_ connection: NWConnection) async {
        do {
            let channel = try await TlsChannel.accept(connection)
            defer { Task { await channel.close() } }
            let ours = PeerInfo(type: PeerInfo.Kind.deviceGuid.rawValue, data: Data(guid.utf8))
            let theirs = try await PairingSession(channel: TlsPairingChannel(channel), role: .server)
                .run(code: Data(code.utf8), ourInfo: ours)
            continuation.yield(.success(Paired(peerInfo: theirs)))
        } catch {
            Self.logger.error("Pairing server: \(String(describing: error), privacy: .public)")
            connection.cancel()
            continuation.yield(.failure(error))
        }
    }
}
