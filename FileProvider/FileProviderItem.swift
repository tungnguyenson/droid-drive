import DeviceService
import DroidCore
import FileProvider
import ItemStore
import UniformTypeIdentifiers

/// An `ItemStore` row as File Provider sees it.
final class FileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    /// Declared under NSFileProviderDecorations in Info.plist (project.yml).
    static let conflictDecoration = NSFileProviderItemDecorationIdentifier(
        (Bundle.main.bundleIdentifier ?? "dev.droiddrive.app.FileProvider") + ".conflictCopy")

    let stored: StoredItem

    init(_ stored: StoredItem) { self.stored = stored }

    static func identifier(_ storeId: String) -> NSFileProviderItemIdentifier {
        storeId == ItemStore.rootId ? .rootContainer : NSFileProviderItemIdentifier(storeId)
    }

    static func storeId(_ identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? ItemStore.rootId : identifier.rawValue
    }

    var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(stored.id) }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        stored.parentId.map(Self.identifier) ?? .rootContainer
    }

    var filename: String { stored.parentId == nil ? "/" : stored.name }

    var contentType: UTType {
        if stored.kind == .directory { return .folder }
        let ext = (stored.name as NSString).pathExtension
        return ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
    }

    var capabilities: NSFileProviderItemCapabilities {
        if stored.parentId == nil { return [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating] }
        var caps: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                                                    .allowsReparenting, .allowsDeleting]
        if stored.kind == .directory { caps.formUnion([.allowsAddingSubItems, .allowsContentEnumerating]) }
        return caps
    }

    /// Content version is the device version (size + mtime); metadata version adds the
    /// path, so a rename is a metadata change only.
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data(stored.version.utf8),
                                  metadataVersion: Data("\(stored.version)|\(stored.path.string)".utf8))
    }

    /// FR-18: Finder draws the sync states (not downloaded, downloading, waiting to
    /// upload, upload error) itself. The one state it cannot know is "this is the Mac's
    /// copy kept after a conflict" (spec §5.5), which gets a warning badge.
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        guard stored.kind == .file, ConflictCopy.matches(stored.name) else { return nil }
        return [Self.conflictDecoration]
    }

    var documentSize: NSNumber? { stored.kind == .directory ? nil : NSNumber(value: stored.size) }
    var contentModificationDate: Date? { stored.mtime }
    var creationDate: Date? { stored.mtime }
}
