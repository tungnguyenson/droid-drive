import DroidCore
import FileProvider
import ItemStore

/// Enumerates one folder, or the working set (spec §5.5 "Ánh xạ thao tác").
///
/// - Folder, first page: list the directory from the device into the store, then serve
///   pages of 500 from the store so Finder fills in as it scrolls.
/// - Working set changes: re-list every folder Finder has opened, then report what the
///   store's generation counter says changed. The app triggers this every refresh period
///   with `signalEnumerator(for: .workingSet)`.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    static let pageSize = 500

    private let context: DomainContext
    /// nil for the working set.
    private let containerId: String?
    private var tasks: [Task<Void, Never>] = []

    init(context: DomainContext, container: NSFileProviderItemIdentifier) {
        self.context = context
        containerId = container == .workingSet ? nil : FileProviderItem.storeId(container)
    }

    func invalidate() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let containerId else {
            // Everything reaches the system through folder enumeration and changes.
            observer.finishEnumerating(upTo: nil)
            return
        }
        let context = context
        tasks.append(Task {
            do {
                guard let container = try context.store.item(id: containerId) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let offset = Self.offset(of: page)
                let started = ContinuousClock.now
                if offset == 0 { try await context.refresh(container) }
                let children = try context.store.children(of: containerId)
                let end = min(offset + Self.pageSize, children.count)
                log.info("enumerate \(container.path.string, privacy: .private) from \(offset): \(end - min(offset, end)) of \(children.count) in \(ContinuousClock.now - started, privacy: .public)")
                if offset < end { observer.didEnumerate(children[offset..<end].map(FileProviderItem.init)) }
                observer.finishEnumerating(upTo: end < children.count ? Self.page(end) : nil)
            } catch {
                log.error("enumerate failed: \(String(describing: error), privacy: .public)")
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        })
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let context = context
        let refreshAll = containerId == nil
        tasks.append(Task {
            do {
                if refreshAll {
                    for directory in try context.store.listedDirectories() {
                        try Task.checkCancellation()
                        try await context.refresh(directory)
                    }
                }
                let changes = try context.store.changes(since: Self.generation(of: anchor))
                log.info("changes \(refreshAll ? "working set" : "folder", privacy: .public) since \(Self.generation(of: anchor)): \(changes.updated.count) updated, \(changes.deleted.count) deleted")
                for start in stride(from: 0, to: changes.updated.count, by: Self.pageSize) {
                    let slice = changes.updated[start..<min(start + Self.pageSize, changes.updated.count)]
                    observer.didUpdate(slice.map(FileProviderItem.init))
                }
                if !changes.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: changes.deleted.map(FileProviderItem.identifier))
                }
                observer.finishEnumeratingChanges(upTo: Self.anchor(changes.anchor), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        })
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor(context.store.currentGeneration))
    }

    // MARK: Encoding pages and anchors

    static func anchor(_ generation: Int64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(withUnsafeBytes(of: generation.littleEndian) { Data($0) })
    }

    static func generation(of anchor: NSFileProviderSyncAnchor) -> Int64 {
        decodeInt(anchor.rawValue)
    }

    static func page(_ offset: Int) -> NSFileProviderPage {
        NSFileProviderPage(withUnsafeBytes(of: Int64(offset).littleEndian) { Data($0) })
    }

    /// The system's initial pages (sorted by name/date) are not 8 bytes; they mean 0.
    static func offset(of page: NSFileProviderPage) -> Int {
        let data = page.rawValue
        if data == NSFileProviderPage.initialPageSortedByName as Data
            || data == NSFileProviderPage.initialPageSortedByDate as Data {
            return 0
        }
        return Int(max(0, decodeInt(data)))
    }

    private static func decodeInt(_ data: Data) -> Int64 {
        guard data.count == 8 else { return 0 }
        return data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
    }
}
