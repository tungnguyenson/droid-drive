import DeviceService
import DroidCore
import FileProvider
import os

private let log = Logger(subsystem: "com.droiddrive.app", category: "link")

/// Lends the app's device connections to the File Provider extension (plan P1-11).
///
/// A sandboxed app cannot publish a Mach service the extension could look up, so the
/// app connects to the extension instead: each domain's extension vends a
/// `DeviceLinkServiceSource`, reached with `NSFileProviderManager.service(named:for:)`
/// (macOS 13+). The extension asks for that connection with a Darwin notification
/// whenever it needs the device and has none (it just started, or the app restarted);
/// the app observes one notification name per mounted domain.
@MainActor
final class ExtensionLinker {
    private let makeHost: (DomainIdentifier) -> DeviceHost
    private var domains: [String: NSFileProviderDomain] = [:]
    private var connections: [String: NSXPCConnection] = [:]
    private var connecting: Set<String> = []

    init(makeHost: @escaping (DomainIdentifier) -> DeviceHost) {
        self.makeHost = makeHost
    }

    var linkedDomains: Set<String> { Set(connections.keys) }

    /// Observes the link requests of exactly these domains.
    func observe(_ current: [NSFileProviderDomain]) {
        let byId = Dictionary(current.map { ($0.identifier.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        for id in Set(domains.keys).subtracting(byId.keys) {
            removeObserver(id)
            connections.removeValue(forKey: id)?.invalidate()
        }
        for id in Set(byId.keys).subtracting(domains.keys) {
            addObserver(id)
        }
        domains = byId
    }

    /// Opens (or reopens) the link to one domain's extension.
    func connect(_ domainId: String) async {
        guard let domain = domains[domainId], let id = DomainIdentifier(rawValue: domainId),
              connecting.insert(domainId).inserted else { return }
        defer { connecting.remove(domainId) }
        do {
            guard let manager = NSFileProviderManager(for: domain),
                  let service = try await manager.service(named: NSFileProviderServiceName(DeviceLink.serviceName),
                                                          for: .rootContainer) else {
                log.error("extension offers no device link for \(domainId, privacy: .public)")
                return
            }
            let connection = try await service.fileProviderConnection()
            let host = makeHost(id)
            connection.invalidationHandler = { [weak self, weak connection] in
                Task { @MainActor in self?.dropped(domainId, connection) }
            }
            let served = try await host.serve(connection)
            guard served == domainId else {
                log.error("extension answered for \(served, privacy: .public), expected \(domainId, privacy: .public)")
                connection.invalidate()
                return
            }
            connections.removeValue(forKey: domainId)?.invalidate()
            connections[domainId] = connection
            log.info("linked \(domainId, privacy: .public)")
        } catch {
            log.error("cannot link \(domainId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func dropped(_ domainId: String, _ connection: NSXPCConnection?) {
        if let connection, connections[domainId] === connection {
            connections[domainId] = nil
            log.info("link closed for \(domainId, privacy: .public)")
        }
    }

    // MARK: Darwin notifications

    private func notificationName(_ domainId: String) -> CFNotificationName {
        CFNotificationName(DeviceLink.linkRequestNotification(appGroup: AppGroup.identifier,
                                                              domainIdentifier: domainId) as CFString)
    }

    private var observerToken: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()) }

    private func addObserver(_ domainId: String) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observerToken, { _, observer, name, _, _ in
            guard let observer, let raw = name?.rawValue as String? else { return }
            let linker = Unmanaged<ExtensionLinker>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in linker.handle(raw) }
        }, notificationName(domainId).rawValue, nil, .deliverImmediately)
    }

    private func removeObserver(_ domainId: String) {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), observerToken,
                                           notificationName(domainId), nil)
    }

    private func handle(_ notification: String) {
        let prefix = DeviceLink.linkRequestNotification(appGroup: AppGroup.identifier, domainIdentifier: "")
        guard notification.hasPrefix(prefix) else { return }
        let domainId = String(notification.dropFirst(prefix.count))
        log.info("extension asked for a link: \(domainId, privacy: .public)")
        Task { await connect(domainId) }
    }
}
