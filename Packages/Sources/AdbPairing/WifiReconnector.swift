import AdbKit
import DroidCore
import Foundation
import os

/// Reconnects paired phones by themselves (spec §5.4, plan P3-08, FR-15): when a
/// phone in the `PairedDeviceStore` advertises `_adb-tls-connect._tcp` (its service name
/// is the GUID it gave us when pairing), connect over TLS and hand the app a ready
/// transport. Phones switched with `tcpip` (Android 10 and earlier) have no mDNS, so
/// their last address is retried every `tcpipRetryInterval`.
public actor WifiReconnector {
    public enum Event: Sendable {
        case connected(PairedDevice, AdbTransport)
        /// A known phone was seen but the connection failed. `permissionDenied` means the
        /// phone no longer trusts this Mac (unpaired on the phone): pair again.
        case failed(PairedDevice, any Error)
    }

    public nonisolated let events: AsyncStream<Event>
    private nonisolated let continuation: AsyncStream<Event>.Continuation
    private let store: PairedDeviceStore
    private let connector: WifiConnector
    private let discovery: @Sendable () -> AsyncStream<[WifiService]>
    private let tcpipRetryInterval: Duration
    private var busy: Set<String> = []
    private var connected: Set<String> = []
    private var tasks: [Task<Void, Never>] = []
    private static let logger = Logger(subsystem: "com.droiddrive", category: "wifi")

    public init(store: PairedDeviceStore, connector: WifiConnector, tcpipRetryInterval: Duration = .seconds(60)) {
        self.init(store: store, connector: connector, tcpipRetryInterval: tcpipRetryInterval,
                  discovery: { WifiDiscovery.services([.connect]) })
    }

    init(store: PairedDeviceStore, connector: WifiConnector, tcpipRetryInterval: Duration,
         discovery: @escaping @Sendable () -> AsyncStream<[WifiService]>) {
        self.store = store
        self.connector = connector
        self.tcpipRetryInterval = tcpipRetryInterval
        self.discovery = discovery
        (events, continuation) = AsyncStream.makeStream()
    }

    public func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [discovery] in
            for await snapshot in discovery() {
                await self.handle(snapshot)
            }
        })
        tasks.append(Task {
            while !Task.isCancelled {
                await self.retryTcpip()
                try? await Task.sleep(for: self.tcpipRetryInterval)
            }
        })
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        continuation.finish()
    }

    /// The app calls this when a transport it got from us drops, so the next
    /// advertisement (or tcpip retry) reconnects.
    public func markDisconnected(id: String) { connected.remove(id) }

    func handle(_ snapshot: [WifiService]) async {
        let advertised = Set(snapshot.map(\.name))
        // A phone that stopped advertising has dropped off the network.
        connected.formIntersection(advertised.union(tcpipIds()))
        guard let devices = try? await store.all() else { return }
        for service in snapshot where service.kind == .connect {
            guard let host = service.host, let port = service.port,
                  let device = devices.first(where: { $0.kind == .paired && $0.id == service.name }) else { continue }
            await attempt(device, host: host, port: port, tls: true)
        }
    }

    private var tcpipKnown: Set<String> = []
    private func tcpipIds() -> Set<String> { tcpipKnown }

    func retryTcpip() async {
        guard let devices = try? await store.all() else { return }
        tcpipKnown = Set(devices.filter { $0.kind == .tcpip }.map(\.id))
        for device in devices where device.kind == .tcpip {
            guard let host = device.lastHost else { continue }
            await attempt(device, host: host, port: device.lastPort ?? TcpipSwitch.defaultPort, tls: false)
        }
    }

    private func attempt(_ device: PairedDevice, host: String, port: UInt16, tls: Bool) async {
        guard !connected.contains(device.id), !busy.contains(device.id) else { return }
        busy.insert(device.id)
        defer { busy.remove(device.id) }
        do {
            let transport = try await connector.transport(host: host, port: port, tls: tls)
            connected.insert(device.id)
            try? await store.noteConnected(id: device.id, host: host, port: port,
                                           serial: transport.info.serial, model: transport.info.model)
            Self.logger.info("Reconnected \(device.id, privacy: .public) at \(host, privacy: .public):\(port)")
            continuation.yield(.connected(device, transport))
        } catch {
            Self.logger.error("Reconnect \(device.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            if tls { continuation.yield(.failed(device, error)) }
        }
    }
}
