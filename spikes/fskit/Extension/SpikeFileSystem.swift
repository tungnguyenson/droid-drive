import FSKit
import Foundation
import os

private let log = Logger(subsystem: "com.droiddrive.fskitspike", category: "fs")

/// Spike S0-d: can FSKit mount a file system that is not backed by a block device, and how
/// fast does a large directory list? Mounted from a generic URL such as
/// `droidspike://test?files=10000`; the tree is generated in memory, read-only.
@main
struct SpikeExtension: UnaryFileSystemExtension {
    var fileSystem: SpikeFileSystem { SpikeFileSystem() }
}

final class SpikeFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let url = (resource as? FSGenericURLResource)?.url, url.scheme == "droidspike" else {
            return .notRecognized
        }
        return .usable(name: url.host ?? "spike", containerID: FSContainerIdentifier(uuid: UUID()))
    }

    func loadResource(resource: FSResource, options: FSTaskOptions) async throws -> FSVolume {
        guard let url = (resource as? FSGenericURLResource)?.url else { throw fs_errorForPOSIXError(EINVAL) }
        let files = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "files" })?.value.flatMap(Int.init) ?? 10_000
        log.notice("load \(url.absoluteString, privacy: .public) files=\(files)")
        containerStatus = .ready
        return SpikeVolume(name: url.host ?? "spike", files: files)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {}
}

final class SpikeItem: FSItem, @unchecked Sendable {
    let id: UInt64
    let name: String
    let isDirectory: Bool
    let size: UInt64
    init(id: UInt64, name: String, isDirectory: Bool, size: UInt64) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// Root: `hello.txt` and `many/` with `files` small files.
final class SpikeVolume: FSVolume, FSVolume.Operations, FSVolume.PathConfOperations,
    FSVolume.OpenCloseOperations, FSVolume.ReadWriteOperations, @unchecked Sendable {
    static let rootID: UInt64 = 2
    static let helloID: UInt64 = 3
    static let manyID: UInt64 = 4
    static let firstFileID: UInt64 = 100
    static let hello = Data("hello from FSKit\n".utf8)

    let files: Int
    let root: SpikeItem
    let helloItem: SpikeItem
    let many: SpikeItem

    init(name: String, files: Int) {
        self.files = files
        root = SpikeItem(id: Self.rootID, name: "", isDirectory: true, size: 0)
        helloItem = SpikeItem(id: Self.helloID, name: "hello.txt", isDirectory: false, size: UInt64(Self.hello.count))
        many = SpikeItem(id: Self.manyID, name: "many", isDirectory: true, size: 0)
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()), volumeName: FSFileName(string: name))
    }

    private func file(_ index: Int) -> SpikeItem {
        SpikeItem(id: Self.firstFileID + UInt64(index), name: String(format: "file-%05d.txt", index + 1),
                  isDirectory: false, size: 64)
    }

    private func item(_ fsItem: FSItem) throws -> SpikeItem {
        guard let item = fsItem as? SpikeItem else { throw fs_errorForPOSIXError(EINVAL) }
        return item
    }

    private func attributes(of item: SpikeItem, parent: UInt64) -> FSItem.Attributes {
        let a = FSItem.Attributes()
        a.type = item.isDirectory ? .directory : .file
        a.mode = item.isDirectory ? UInt32(S_IFDIR | 0o755) : UInt32(S_IFREG | 0o644)
        a.linkCount = item.isDirectory ? 2 : 1
        a.size = item.size
        a.allocSize = item.size
        a.fileID = FSItem.Identifier(rawValue: item.id) ?? .invalid
        a.parentID = FSItem.Identifier(rawValue: parent) ?? .invalid
        a.uid = getuid()
        a.gid = getgid()
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        a.modifyTime = now
        a.changeTime = now
        a.accessTime = now
        a.birthTime = now
        return a
    }

    private func parentID(of item: SpikeItem) -> UInt64 {
        item.id >= Self.firstFileID ? Self.manyID : Self.rootID
    }

    // MARK: Volume

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.supports64BitObjectIDs = true
        c.supportsPersistentObjectIDs = true
        c.caseFormat = .sensitive
        return c
    }

    var volumeStatistics: FSStatFSResult {
        let s = FSStatFSResult(fileSystemTypeName: "droidspike")
        s.blockSize = 4096
        s.ioSize = 1 << 20
        s.totalBlocks = 1 << 20
        s.freeBlocks = 1 << 19
        s.availableBlocks = 1 << 19
        s.usedBlocks = 1 << 19
        s.totalFiles = UInt64(files + 3)
        return s
    }

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    func mount(options: FSTaskOptions) async throws {}
    func unmount() async {}
    func synchronize(flags: FSSyncFlags) async throws {}
    func activate(options: FSTaskOptions) async throws -> FSItem { root }
    func deactivate(options: FSDeactivateOptions) async throws {}

    func attributes(_ desired: FSItem.GetAttributesRequest, of fsItem: FSItem) async throws -> FSItem.Attributes {
        let item = try item(fsItem)
        return attributes(of: item, parent: parentID(of: item))
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        throw fs_errorForPOSIXError(EROFS)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        let dir = try item(directory)
        let wanted = name.string ?? ""
        if dir.id == Self.rootID {
            if wanted == "hello.txt" { return (helloItem, name) }
            if wanted == "many" { return (many, name) }
        } else if dir.id == Self.manyID, wanted.hasPrefix("file-"), wanted.hasSuffix(".txt"),
                  let n = Int(wanted.dropFirst(5).dropLast(4)), n >= 1, n <= files {
            return (file(n - 1), name)
        }
        throw fs_errorForPOSIXError(ENOENT)
    }

    func reclaimItem(_ item: FSItem) async throws {}

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName { throw fs_errorForPOSIXError(EINVAL) }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(EROFS)
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(EROFS)
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        throw fs_errorForPOSIXError(EROFS)
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        throw fs_errorForPOSIXError(EROFS)
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        throw fs_errorForPOSIXError(EROFS)
    }

    /// Cookie = index of the next entry (0-based, after "." and ".." handled by FSKit).
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        let dir = try item(directory)
        let entries: Int = dir.id == Self.rootID ? 2 : files
        var index = Int(cookie.rawValue)
        while index < entries {
            let child: SpikeItem = dir.id == Self.rootID ? (index == 0 ? helloItem : many) : file(index)
            let attrs = attributes == nil ? nil : self.attributes(of: child, parent: dir.id)
            let packed = packer.packEntry(name: FSFileName(string: child.name),
                                          itemType: child.isDirectory ? .directory : .file,
                                          itemID: FSItem.Identifier(rawValue: child.id) ?? .invalid,
                                          nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)),
                                          attributes: attrs)
            if !packed { break }
            index += 1
        }
        return FSDirectoryVerifier(rawValue: 1)
    }

    // MARK: Open, read

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        if modes.contains(.write) { throw fs_errorForPOSIXError(EROFS) }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {}

    func read(from fsItem: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        let item = try item(fsItem)
        let content = item.id == Self.helloID ? Self.hello : Data(repeating: UInt8(ascii: "x"), count: Int(item.size))
        guard offset < content.count else { return 0 }
        let slice = content[Int(offset)..<min(content.count, Int(offset) + length)]
        return buffer.withUnsafeMutableBytes { dst in
            slice.copyBytes(to: dst)
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        throw fs_errorForPOSIXError(EROFS)
    }
}
