import DeviceService
import DroidCore
import FileProvider
import ItemStore

/// One instance per domain (one storage of one phone). macOS starts and stops it.
///
/// Safety rule (spec §12): a write or delete on the phone goes ahead only when the
/// phone's version still equals the version Finder based its change on. Otherwise the
/// Mac's edit is kept as "Name (Mac copy).ext" and the phone's file is left alone.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing {
    private let context: DomainContext?
    private let setupError: Error?

    required init(domain: NSFileProviderDomain) {
        do {
            context = try DomainContext(domain: domain)
            setupError = nil
        } catch {
            log.fault("cannot open domain \(domain.identifier.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            context = nil
            setupError = error
        }
        super.init()
    }

    func invalidate() {
        context?.link.reset()
    }

    // MARK: Device link (plan P1-11)

    /// The app connects to this service to lend the extension its device connection.
    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        guard let context else {
            completionHandler(nil, setupError ?? NSFileProviderError(.providerNotFound))
            return Progress()
        }
        completionHandler([DeviceLinkServiceSource(listener: context.listener)], nil)
        return Progress()
    }

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        do {
            let context = try requireContext()
            guard let stored = try context.store.item(id: FileProviderItem.storeId(identifier)) else {
                throw NSFileProviderError(.noSuchItem)
            }
            completionHandler(FileProviderItem(stored), nil)
        } catch {
            completionHandler(nil, error)
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        run(progress, onError: { completionHandler(nil, nil, $0) }) { context in
            guard let stored = try context.store.item(id: FileProviderItem.storeId(itemIdentifier)),
                  let parentId = stored.parentId else { throw NSFileProviderError(.noSuchItem) }
            let url = try context.temporaryFileURL()
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let entry = try await context.withDevice { transport -> RemoteEntry in
                let child = Progress()
                progress.addChild(child, withPendingUnitCount: 100)
                try await transport.read(stored.path, to: handle, range: nil, progress: child)
                return try await transport.stat(stored.path)
            }
            let updated = try context.store.record(entry, parentId: parentId)
            completionHandler(url, FileProviderItem(updated), nil)
        }
        return progress
    }

    // MARK: Create

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        run(progress, onError: { completionHandler(nil, [], false, $0) }) { context in
            guard let parent = try context.store.item(id: FileProviderItem.storeId(itemTemplate.parentItemIdentifier)) else {
                throw NSFileProviderError(.noSuchItem)
            }
            let name = try FileName.validate(itemTemplate.filename)
            let path = parent.path.appending(name)
            let isFolder = itemTemplate.contentType == .folder
            if itemTemplate.contentType == .symbolicLink {
                throw DeviceError.unsupported("Symbolic links cannot be created on the phone")
            }
            var keptBoth = false
            let entry = try await context.withDevice { transport -> RemoteEntry in
                if let existing = try? await transport.stat(path) {
                    // Re-import, or a folder of the same name: adopt what is there.
                    if options.contains(.mayAlreadyExist) || (isFolder && existing.kind == .directory) {
                        return existing
                    }
                    // The phone has a file of this name that Finder did not know about:
                    // keep both, the Mac's copy under the conflict name (spec §5.5).
                    keptBoth = true
                    let copyPath = try await Self.freeConflictPath(for: path, transport: transport)
                    return try await Self.upload(url, to: copyPath, mtime: itemTemplate.contentModificationDate ?? nil,
                                                 transport: transport, context: context, progress: progress)
                }
                if isFolder { return try await transport.mkdir(path) }
                return try await Self.upload(url, to: path, mtime: itemTemplate.contentModificationDate ?? nil,
                                             transport: transport, context: context, progress: progress)
            }
            if keptBoth { context.manager?.signalEnumerator(for: .workingSet) { _ in } }
            let stored = try context.store.record(entry, parentId: parent.id)
            if stored.kind == .directory { try context.store.markListed(id: stored.id) }
            completionHandler(FileProviderItem(stored), [], false, nil)
        }
        return progress
    }

    // MARK: Modify

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        run(progress, onError: { completionHandler(nil, [], false, $0) }) { context in
            guard var current = try context.store.item(id: FileProviderItem.storeId(item.itemIdentifier)),
                  current.parentId != nil else { throw NSFileProviderError(.noSuchItem) }

            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                guard let newParent = try context.store.item(id: FileProviderItem.storeId(item.parentItemIdentifier)) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let newPath = newParent.path.appending(try FileName.validate(item.filename))
                if Array(newPath.string.utf8) != Array(current.path.string.utf8) {
                    let from = current.path
                    let moved = try await context.withDevice { try await $0.rename(from, to: newPath) }
                    current = try context.store.move(id: current.id, to: moved, parentId: newParent.id)
                }
            }

            if changedFields.contains(.contents), let newContents, current.kind == .file {
                let base = String(decoding: version.contentVersion, as: UTF8.self)
                let target = current
                let outcome = try await context.withDevice { transport -> (RemoteEntry, conflict: RemoteEntry?) in
                    let onPhone = try? await transport.stat(target.path)
                    if let onPhone, onPhone.version != base {
                        // The phone changed since Finder's copy: keep both (spec §5.5).
                        let copyPath = try await Self.freeConflictPath(for: target.path, transport: transport)
                        let copy = try await Self.upload(newContents, to: copyPath, mtime: item.contentModificationDate ?? nil,
                                                         transport: transport, context: context, progress: progress)
                        return (onPhone, copy)
                    }
                    let written = try await Self.upload(newContents, to: target.path, mtime: item.contentModificationDate ?? nil,
                                                        transport: transport, context: context, progress: progress)
                    return (written, nil)
                }
                current = try context.store.record(outcome.0, parentId: current.parentId!)
                if let conflict = outcome.conflict {
                    _ = try context.store.record(conflict, parentId: current.parentId!)
                    context.manager?.signalEnumerator(for: .workingSet) { _ in }
                    // Finder re-downloads the phone's version; the Mac's edit shows up as the copy.
                    completionHandler(FileProviderItem(current), [], true, nil)
                    return
                }
            }
            // Mtime-only and other metadata changes are not stored on the phone.
            completionHandler(FileProviderItem(current), [], false, nil)
        }
        return progress
    }

    // MARK: Delete

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        run(progress, onError: completionHandler) { context in
            guard let stored = try context.store.item(id: FileProviderItem.storeId(identifier)),
                  stored.parentId != nil else {
                completionHandler(nil)
                return
            }
            let base = String(decoding: version.contentVersion, as: UTF8.self)
            try await context.withDevice { transport in
                guard let onPhone = try? await transport.stat(stored.path) else { return }
                if onPhone.kind == .file && onPhone.version != base {
                    // Changed on the phone after Finder's copy: refuse; macOS restores the item.
                    throw NSFileProviderError(.deletionRejected)
                }
                try await transport.delete(stored.path, recursive: true)
            }
            try context.store.remove(id: stored.id)
            progress.completedUnitCount = 1
            completionHandler(nil)
        }
        return progress
    }

    // MARK: Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer { throw NSFileProviderError(.noSuchItem) }
        return FileProviderEnumerator(context: try requireContext(), container: containerItemIdentifier)
    }

    // MARK: Helpers

    private func requireContext() throws -> DomainContext {
        guard let context else { throw setupError ?? NSFileProviderError(.providerNotFound) }
        return context
    }

    /// Runs `body` in a task tied to `progress` (cancelling the progress cancels the task)
    /// and routes every thrown error through `fileProviderError`.
    private func run(_ progress: Progress, onError: @escaping (Error) -> Void,
                     _ body: @escaping (DomainContext) async throws -> Void) {
        let context: DomainContext
        do {
            context = try requireContext()
        } catch {
            onError(error)
            return
        }
        let task = Task {
            do {
                try await body(context)
            } catch {
                onError(fileProviderError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
    }

    /// First "Name (Mac copy[ n]).ext" next to `path` that the phone does not have.
    private static func freeConflictPath(for path: RemotePath, transport: some DeviceTransport) async throws -> RemotePath {
        for attempt in 1...100 {
            let candidate = path.parent.appending(FileName.conflictName(for: path.name, attempt: attempt))
            if (try? await transport.stat(candidate)) == nil { return candidate }
        }
        throw DeviceError.exists(path)
    }

    private static func upload(_ url: URL?, to path: RemotePath, mtime: Date?, transport: some DeviceTransport,
                               context: DomainContext, progress: Progress) async throws -> RemoteEntry {
        let source = try url ?? context.temporaryFileURL()
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let child = Progress()
        progress.addChild(child, withPendingUnitCount: 100)
        return try await transport.write(path, from: handle, mtime: mtime, progress: child)
    }
}

/// Hands the app the endpoint of this domain's device-link listener.
final class DeviceLinkServiceSource: NSObject, NSFileProviderServiceSource {
    let serviceName = NSFileProviderServiceName(DeviceLink.serviceName)
    private let listener: DeviceLinkListener

    init(listener: DeviceLinkListener) {
        self.listener = listener
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        listener.endpoint
    }

    /// Only a process that can manage the domain (DroidDrive.app) may connect.
    var isRestricted: Bool { true }
}
