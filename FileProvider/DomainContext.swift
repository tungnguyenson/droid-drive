import DeviceService
import DroidCore
import FileProvider
import ItemStore
import os

let log = Logger(subsystem: "com.droiddrive.fileprovider", category: "extension")

/// Everything one domain instance needs: its store, how to reach the device, and the
/// directory refresh logic shared by the extension and its enumerators.
///
/// The device is reached through the app (spec §5.1, plan P1-11): the app owns every
/// connection to the phone and connects to this domain's `DeviceLinkServiceSource`
/// when asked. `HostLink` asks by posting a Darwin notification and waits briefly; if
/// the app is not running, device calls fail with `disconnected`, reported to macOS as
/// `serverUnreachable`, so edits stay queued until the app signals the domain (FR-10).
final class DomainContext: @unchecked Sendable {
    let domain: NSFileProviderDomain
    let id: DomainIdentifier
    let store: ItemStore
    let link: HostLink
    let listener: DeviceLinkListener
    private let lock = NSLock()
    private var cached: RemoteDeviceTransport?

    init(domain: NSFileProviderDomain) throws {
        guard let id = DomainIdentifier(rawValue: domain.identifier.rawValue) else {
            throw NSFileProviderError(.providerNotFound)
        }
        self.domain = domain
        self.id = id
        store = try ItemStore(url: AppGroup.itemStoreURL(domainIdentifier: domain.identifier.rawValue), root: id.root)
        let notification = DeviceLink.linkRequestNotification(appGroup: AppGroup.identifier,
                                                              domainIdentifier: domain.identifier.rawValue)
        link = HostLink(domainIdentifier: domain.identifier.rawValue) {
            log.info("asking DroidDrive.app to connect")
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName(notification as CFString), nil, nil, true)
        }
        let requirement = DeviceLink.hostRequirement(appBundleId: AppGroup.hostBundleIdentifier,
                                                     teamId: AppGroup.teamIdentifier)
        if requirement == nil { log.notice("unsigned build: accepting any app on the device link") }
        listener = DeviceLinkListener(link: link, requirement: requirement)
    }

    var manager: NSFileProviderManager? { NSFileProviderManager(for: domain) }

    /// `id.serial` is the phone's own serial; the app picks the connection to it (USB,
    /// Wi-Fi, MTP) and refuses if the phone is not connected.
    func transport() async throws -> any DeviceTransport {
        if let existing = lock.withLock({ cached }) { return existing }
        let transport = try await RemoteDeviceTransport.connect(serial: id.serial, link: link)
        lock.withLock { cached = transport }
        return transport
    }

    /// Runs a device operation; drops the cached transport when the device is gone so
    /// the next call asks the app again.
    func withDevice<T>(_ body: (any DeviceTransport) async throws -> T) async throws -> T {
        do {
            return try await body(try await transport())
        } catch let error as DeviceError where error == .disconnected {
            lock.withLock { cached = nil }
            throw error
        }
    }

    /// Lists one directory from the device into the store (spec §5.5). A directory that
    /// vanished on the phone is removed from the store, but only while the storage itself
    /// is there: an SD card that was taken out looks like every folder vanished, and
    /// Finder would then delete what it downloaded. A missing storage is reported as
    /// unreachable instead, like a pulled cable (plan P1-13).
    func refresh(_ directory: StoredItem) async throws {
        do {
            try await withDevice { transport in
                let listing = try store.beginListing(of: directory.id)
                for try await batch in transport.list(directory.path) {
                    _ = try store.apply(batch, to: listing)
                }
                try store.finishListing(listing)
            }
        } catch let error as DeviceError {
            guard case .notFound = error else { throw error }
            guard directory.id != ItemStore.rootId, try await storagePresent() else {
                log.notice("storage \(self.id.storage, privacy: .public) is not on the phone now")
                throw DeviceError.disconnected
            }
            try store.remove(id: directory.id)
        }
    }

    private func storagePresent() async throws -> Bool {
        do {
            return try await withDevice { try await $0.stat(id.root).kind == .directory }
        } catch DeviceError.notFound {
            return false
        }
    }

    func temporaryFileURL() throws -> URL {
        let dir = try manager?.temporaryDirectoryURL() ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }
}

/// Maps transport errors to what File Provider understands. `serverUnreachable` makes
/// macOS keep the operation queued and retry after `signalErrorResolved` (FR-10).
func fileProviderError(_ error: Error) -> Error {
    guard let device = error as? DeviceError else {
        if error is CancellationError { return CocoaError(.userCancelled) }
        return error
    }
    log.error("device error: \(String(describing: device), privacy: .public)")
    switch device {
    case .disconnected, .busy: return NSFileProviderError(.serverUnreachable)
    case .notFound: return NSFileProviderError(.noSuchItem)
    case .exists: return NSFileProviderError(.filenameCollision)
    case .noSpace: return NSFileProviderError(.insufficientQuota)
    case .permissionDenied: return CocoaError(.fileWriteNoPermission)
    case .invalidName(_, let reason):
        return NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteInvalidFileName.rawValue,
                       userInfo: [NSLocalizedDescriptionKey: reason])
    case .unsupported(let message), .protocolError(let message):
        return NSError(domain: NSCocoaErrorDomain, code: CocoaError.featureUnsupported.rawValue,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}
