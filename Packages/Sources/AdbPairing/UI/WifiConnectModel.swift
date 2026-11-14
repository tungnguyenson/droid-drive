import AdbKit
import DroidCore
import Foundation
import os

/// Drives the "Connect via Wi-Fi" sheet (spec §6, plan P3-07): runs discovery while the
/// sheet is open, waits for the QR code to be scanned, pairs, stores the phone and
/// connects. The app gets ready transports through `onConnected`.
@MainActor
public final class WifiConnectModel: ObservableObject {
    public enum Tab: Hashable, CaseIterable, Sendable {
        case qrCode, pairingCode, manual, legacy

        public var title: String {
            switch self {
            case .qrCode: "QR code"
            case .pairingCode: "Pairing code"
            case .manual: "Manual"
            case .legacy: "Android 10 and earlier"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case idle
        case working(String)
        case succeeded(String)
        case failed(String)
    }

    @Published public var tab: Tab = .qrCode
    @Published public private(set) var qrCode = QrPairingCode.random()
    /// Phones showing "Pair device with pairing code" right now.
    @Published public private(set) var pairingServices: [WifiService] = []
    @Published public var selectedServiceID: WifiService.ID?
    @Published public var pairingCode = ""
    @Published public var manualAddress = ""
    @Published public var manualCode = ""
    /// Optional: the IP address & Port line of the Wireless debugging screen, for networks
    /// where mDNS does not reach the Mac.
    @Published public var manualConnectAddress = ""
    @Published public var legacyAddress = ""
    @Published public private(set) var status: Status = .idle

    /// Called on the main actor for each phone that ends up connected.
    public var onConnected: (@MainActor (PairedDevice, AdbTransport) -> Void)?

    private let connector: WifiConnector
    private let store: PairedDeviceStore
    private var discoveryTask: Task<Void, Never>?
    private var qrTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.droiddrive", category: "wifi-ui")

    public init(connector: WifiConnector, store: PairedDeviceStore) {
        self.connector = connector
        self.store = store
    }

    /// Call when the sheet appears.
    public func start() {
        guard discoveryTask == nil else { return }
        discoveryTask = Task { [weak self] in
            for await snapshot in WifiDiscovery.services([.pairing]) {
                self?.pairingServices = snapshot.filter { !$0.name.hasPrefix("droiddrive-") }
            }
        }
        waitForQrScan()
    }

    /// Call when the sheet disappears.
    public func stop() {
        discoveryTask?.cancel()
        qrTask?.cancel()
        actionTask?.cancel()
        discoveryTask = nil
        qrTask = nil
        actionTask = nil
    }

    public func regenerateQrCode() {
        qrCode = QrPairingCode.random()
        waitForQrScan()
    }

    public var isWorking: Bool {
        if case .working = status { return true }
        return false
    }

    public var canPairSelected: Bool {
        selectedServiceID != nil && Self.isSixDigits(pairingCode) && !isWorking
    }

    public var canPairManually: Bool {
        (try? PairingClient.parseAddress(manualAddress)) != nil && Self.isSixDigits(manualCode) && !isWorking
    }

    public var canConnectLegacy: Bool { Self.legacyEndpoint(legacyAddress) != nil && !isWorking }

    static func isSixDigits(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.count == 6 && trimmed.allSatisfy(\.isASCII) && trimmed.allSatisfy(\.isNumber)
    }

    /// "192.168.1.23" (port 5555) or "192.168.1.23:5555".
    static func legacyEndpoint(_ text: String) -> (host: String, port: UInt16)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let parsed = try? PairingClient.parseAddress(trimmed) { return parsed }
        guard !trimmed.isEmpty, !trimmed.contains(":"), !trimmed.contains(where: \.isWhitespace) else { return nil }
        return (trimmed, TcpipSwitch.defaultPort)
    }

    // MARK: Actions

    public func pairSelected() {
        guard let service = pairingServices.first(where: { $0.id == selectedServiceID }) else { return }
        let code = pairingCode
        run("Pairing with \(service.serialHint ?? service.name)…") { client in
            try await client.pair(service: service, code: code)
        }
    }

    public func pairManually() {
        guard let address = try? PairingClient.parseAddress(manualAddress) else { return }
        let code = manualCode
        let connectAddress = try? PairingClient.parseAddress(manualConnectAddress)
        run("Pairing with \(address.host)…", connectHint: connectAddress) { client in
            try await client.pair(host: address.host, port: address.port, code: code)
        }
    }

    public func connectLegacy() {
        guard let endpoint = Self.legacyEndpoint(legacyAddress) else { return }
        status = .working("Connecting to \(endpoint.host)… Allow the connection on the phone if asked.")
        actionTask = Task { [connector, store] in
            do {
                let transport = try await connector.transport(host: endpoint.host, port: endpoint.port, tls: false)
                let device = PairedDevice(id: transport.info.serial.isEmpty ? "\(endpoint.host):\(endpoint.port)" : transport.info.serial,
                                          serial: transport.info.serial, kind: .tcpip, model: transport.info.model,
                                          lastHost: endpoint.host, lastPort: endpoint.port)
                try? await store.upsert(device)
                self.connected(device, transport)
            } catch {
                self.status = .failed(Self.message(for: error))
            }
        }
    }

    private func waitForQrScan() {
        qrTask?.cancel()
        let code = qrCode
        qrTask = Task { [weak self, connector] in
            do {
                let result = try await PairingClient(connector: connector).pair(qr: code, timeout: .seconds(600))
                await self?.finishPairing(result, connectHint: nil)
            } catch is CancellationError {
            } catch WifiPairingError.serviceNotFound {
                // Expired unused; a fresh code is made when the sheet is opened again.
            } catch {
                self?.status = .failed(Self.message(for: error))
            }
        }
    }

    private func run(_ message: String, connectHint: (host: String, port: UInt16)? = nil,
                     pair: @escaping @Sendable (PairingClient) async throws -> PairingResult) {
        status = .working(message)
        actionTask = Task { [connector] in
            do {
                let result = try await pair(PairingClient(connector: connector))
                await self.finishPairing(result, connectHint: connectHint)
            } catch {
                self.status = .failed(Self.message(for: error))
            }
        }
    }

    /// Stores the phone, then connects: through its `_adb-tls-connect._tcp`
    /// advertisement, or the address the user typed.
    private func finishPairing(_ result: PairingResult, connectHint: (host: String, port: UInt16)?) async {
        let device = PairedDevice(id: result.guid, kind: .paired, lastHost: result.host)
        try? await store.upsert(device)
        status = .working("Paired. Connecting…")
        do {
            let endpoint: (host: String, port: UInt16)
            if let connectHint {
                endpoint = connectHint
            } else {
                let service = try await WifiDiscovery.waitFor(.connect, named: result.guid, timeout: .seconds(20))
                guard let host = service.host, let port = service.port else { throw WifiPairingError.serviceNotFound(result.guid) }
                endpoint = (host, port)
            }
            let transport = try await connector.transport(host: endpoint.host, port: endpoint.port)
            try? await store.noteConnected(id: device.id, host: endpoint.host, port: endpoint.port,
                                           serial: transport.info.serial, model: transport.info.model)
            connected(device, transport)
        } catch {
            Self.logger.error("Connect after pairing failed: \(String(describing: error), privacy: .public)")
            status = .succeeded("Paired. DroidDrive will connect as soon as the phone shows up on this network.")
        }
    }

    private func connected(_ device: PairedDevice, _ transport: AdbTransport) {
        let name = [transport.info.manufacturer, transport.info.model].filter { !$0.isEmpty }.joined(separator: " ")
        status = .succeeded("Connected to \(name.isEmpty ? device.id : name).")
        onConnected?(device, transport)
    }

    static func message(for error: Error) -> String {
        if let pairing = error as? WifiPairingError { return pairing.errorDescription ?? "Pairing failed." }
        switch error as? DeviceError {
        case .disconnected?: return "Could not reach the phone. Check that it is on the same Wi-Fi network as this Mac."
        case .permissionDenied?: return "The phone refused this Mac. Pair it again."
        case .unsupported(let text)?, .protocolError(let text)?: return text
        default: return "Something went wrong: \(error.localizedDescription)"
        }
    }
}
