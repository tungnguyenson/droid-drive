import DroidCore
import Foundation
import Network
import os

/// A phone advertising wireless debugging on the local network (spec §5.4, plan P3-04).
public struct WifiService: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        /// "Pair device with pairing code" / QR scan is open on the phone.
        case pairing = "_adb-tls-pairing._tcp"
        /// Wireless debugging is on; a paired Mac may connect.
        case connect = "_adb-tls-connect._tcp"
    }

    public let kind: Kind
    /// The Bonjour instance name: `adb-<serial>-<random>` for pairing codes and for the
    /// connect service (it equals the device GUID pairing returned), or the name we put
    /// in our QR code.
    public let name: String
    public let domain: String
    /// Resolved through DNS-SD; nil until resolution finishes (or if it fails).
    public let host: String?
    public let port: UInt16?
    let interfaceIndex: UInt32

    public var id: String { "\(kind.rawValue)/\(name)" }

    /// `adb-R5CT20ABCDE-xYz12A` → `R5CT20ABCDE`, the phone's `ro.serialno` in practice.
    public var serialHint: String? {
        guard name.hasPrefix("adb-") else { return nil }
        let body = name.dropFirst(4)
        guard let dash = body.lastIndex(of: "-"), dash > body.startIndex else { return nil }
        return String(body[..<dash])
    }

    func resolved(host: String?, port: UInt16?) -> WifiService {
        WifiService(kind: kind, name: name, domain: domain, host: host, port: port, interfaceIndex: interfaceIndex)
    }
}

/// Browses `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp` with `NWBrowser` and
/// resolves each instance to host and port with DNS-SD (which only asks the network,
/// never opens a connection to the phone: a stray connection to the pairing port would
/// count as a failed pairing attempt there).
///
/// The app needs `NSLocalNetworkUsageDescription` and both types under
/// `NSBonjourServices` in Info.plist; macOS asks the user for local network access the
/// first time.
public enum WifiDiscovery {
    private static let logger = Logger(subsystem: "com.droiddrive", category: "wifi")

    /// Every change of the set of advertised services of `kinds`, as a full snapshot
    /// sorted by name. Ends when the consumer stops iterating.
    public static func services(_ kinds: Set<WifiService.Kind> = Set(WifiService.Kind.allCases)) -> AsyncStream<[WifiService]> {
        AsyncStream { continuation in
            let session = DiscoverySession(kinds: kinds) { continuation.yield($0) }
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }

    /// Waits until a service of `kind` named `name` shows up with an address.
    public static func waitFor(_ kind: WifiService.Kind, named name: String,
                               timeout: Duration = .seconds(120)) async throws -> WifiService {
        try await withThrowingTaskGroup(of: WifiService?.self) { group in
            group.addTask {
                for await snapshot in services([kind]) {
                    if let found = snapshot.first(where: { $0.name == name && $0.host != nil && $0.port != nil }) {
                        return found
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let found = first else {
                throw WifiPairingError.serviceNotFound(name)
            }
            return found
        }
    }
}

/// One discovery run: a browser per service type plus a resolver per instance.
final class DiscoverySession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "droiddrive.wifi-discovery")
    private let kinds: Set<WifiService.Kind>
    private let onChange: @Sendable ([WifiService]) -> Void
    // Only touched on `queue`.
    private var browsers: [NWBrowser] = []
    private var services: [String: WifiService] = [:]
    private var resolvers: [String: ServiceResolver] = [:]
    private static let logger = Logger(subsystem: "com.droiddrive", category: "wifi")

    init(kinds: Set<WifiService.Kind>, onChange: @escaping @Sendable ([WifiService]) -> Void) {
        self.kinds = kinds
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                let parameters = NWParameters()
                parameters.includePeerToPeer = false
                let browser = NWBrowser(for: .bonjour(type: kind.rawValue, domain: "local."), using: parameters)
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    self?.update(kind: kind, results: results)
                }
                browser.stateUpdateHandler = { state in
                    if case .failed(let error) = state {
                        Self.logger.error("Browsing \(kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    } else if case .waiting(let error) = state {
                        // Usually "local network access denied" (System Settings → Privacy).
                        Self.logger.error("Browsing \(kind.rawValue, privacy: .public) is waiting: \(error.localizedDescription, privacy: .public)")
                    }
                }
                browser.start(queue: queue)
                browsers.append(browser)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            browsers.forEach { $0.cancel() }
            browsers = []
            resolvers.values.forEach { $0.cancel() }
            resolvers = [:]
        }
    }

    private func update(kind: WifiService.Kind, results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        for result in results {
            guard case let .service(name, _, domain, interface) = result.endpoint else { continue }
            let service = WifiService(kind: kind, name: name, domain: domain, host: nil, port: nil,
                                      interfaceIndex: UInt32(interface?.index ?? 0))
            seen.insert(service.id)
            guard services[service.id] == nil else { continue }
            services[service.id] = service
            let resolver = ServiceResolver(service: service, queue: queue) { [weak self] host, port in
                guard let self, let current = self.services[service.id] else { return }
                self.services[service.id] = current.resolved(host: host, port: port)
                self.publish()
            }
            resolvers[service.id] = resolver
            resolver.start()
        }
        for (id, service) in services where service.kind == kind && !seen.contains(id) {
            services.removeValue(forKey: id)
            resolvers.removeValue(forKey: id)?.cancel()
        }
        publish()
    }

    private func publish() {
        onChange(services.values.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) })
    }
}
