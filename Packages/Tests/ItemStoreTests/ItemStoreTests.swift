import DroidCore
import Foundation
import Testing
@testable import ItemStore

@Suite("ItemStore")
struct ItemStoreTests {
    let root = RemotePath("/storage/emulated/0")
    let store: ItemStore

    init() throws { store = try ItemStore(url: nil, root: root) }

    private func file(_ path: String, size: UInt64 = 1, mtime: TimeInterval = 1000) -> RemoteEntry {
        RemoteEntry(path: root.appending(exact: path), kind: .file, size: size, mtime: Date(timeIntervalSince1970: mtime))
    }

    private func dir(_ path: String) -> RemoteEntry {
        RemoteEntry(path: root.appending(exact: path), kind: .directory, size: 0, mtime: Date(timeIntervalSince1970: 1))
    }

    @discardableResult
    private func list(_ parentId: String, _ entries: [RemoteEntry]) throws -> (items: [StoredItem], removed: [String]) {
        let listing = try store.beginListing(of: parentId)
        let items = try store.apply(entries, to: listing)
        return (items, try store.finishListing(listing))
    }

    @Test("ids are stable across repeated listings")
    func stableIds() throws {
        let first = try list(ItemStore.rootId, [file("a.jpg"), dir("DCIM")]).items
        let second = try list(ItemStore.rootId, [dir("DCIM"), file("a.jpg")]).items
        #expect(Set(first.map(\.id)) == Set(second.map(\.id)))
        #expect(Set(first.map(\.id)).count == 2)
    }

    @Test("an unchanged listing does not bump generations")
    func unchanged() throws {
        try list(ItemStore.rootId, [file("a.jpg")])
        let anchor = store.currentGeneration
        try list(ItemStore.rootId, [file("a.jpg")])
        let changes = try store.changes(since: anchor)
        #expect(changes.updated.isEmpty && changes.deleted.isEmpty)
    }

    @Test("a changed file is reported; a vanished one leaves a tombstone")
    func changesAndTombstones() throws {
        let items = try list(ItemStore.rootId, [file("a.jpg"), file("b.jpg")]).items
        let anchor = store.currentGeneration
        let result = try list(ItemStore.rootId, [file("a.jpg", size: 2)])
        let a = try #require(items.first { $0.name == "a.jpg" })
        let b = try #require(items.first { $0.name == "b.jpg" })
        #expect(result.removed == [b.id])
        let changes = try store.changes(since: anchor)
        #expect(changes.updated.map(\.id) == [a.id])
        #expect(changes.deleted == [b.id])
        #expect(changes.anchor == store.currentGeneration)
    }

    @Test("rename keeps the id and rewrites every descendant path")
    func renameDirectory() throws {
        let photos = try store.record(dir("Photos"), parentId: ItemStore.rootId)
        let trip = try store.record(dir("Photos/Trip"), parentId: photos.id)
        let image = try store.record(file("Photos/Trip/1.jpg"), parentId: trip.id)
        let moved = try store.move(id: photos.id, to: dir("Ảnh"), parentId: ItemStore.rootId)
        #expect(moved.id == photos.id)
        #expect(moved.path == root.appending("Ảnh"))
        let movedImage = try #require(try store.item(id: image.id))
        #expect(movedImage.path == root.appending("Ảnh").appending("Trip").appending("1.jpg"))
        #expect(try store.item(path: root.appending("Ảnh/Trip/1.jpg"))?.id == image.id)
        #expect(try store.item(path: root.appending("Photos")) == nil)
    }

    @Test("a sibling with a shared prefix is not treated as a descendant")
    func prefixSibling() throws {
        let a = try store.record(dir("A"), parentId: ItemStore.rootId)
        _ = try store.record(file("A/x"), parentId: a.id)
        let ab = try store.record(dir("AB"), parentId: ItemStore.rootId)
        let abFile = try store.record(file("AB/y"), parentId: ab.id)
        try store.move(id: a.id, to: dir("Z"), parentId: ItemStore.rootId)
        #expect(try store.item(id: abFile.id)?.path == root.appending("AB/y"))
    }

    @Test("move into another folder updates the parent")
    func moveAcrossFolders() throws {
        let src = try store.record(dir("src"), parentId: ItemStore.rootId)
        let dst = try store.record(dir("dst"), parentId: ItemStore.rootId)
        let doc = try store.record(file("src/doc.pdf"), parentId: src.id)
        let moved = try store.move(id: doc.id, to: file("dst/doc.pdf"), parentId: dst.id)
        #expect(moved.parentId == dst.id)
        #expect(try store.children(of: src.id).isEmpty)
        #expect(try store.children(of: dst.id).map(\.id) == [doc.id])
    }

    @Test("move onto an existing name is refused")
    func moveClash() throws {
        let a = try store.record(file("a.txt"), parentId: ItemStore.rootId)
        _ = try store.record(file("b.txt"), parentId: ItemStore.rootId)
        #expect(throws: DeviceError.exists(root.appending("b.txt"))) {
            try store.move(id: a.id, to: file("b.txt"), parentId: ItemStore.rootId)
        }
    }

    @Test("NFD and NFC spellings of a name are one item; device bytes are kept")
    func unicode() throws {
        let nfc = "Đà Lạt.jpg".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        let first = try store.record(file(nfd), parentId: ItemStore.rootId)
        let second = try store.record(file(nfc, size: 9), parentId: ItemStore.rootId)
        #expect(first.id == second.id)
        #expect(try store.children(of: ItemStore.rootId).count == 1)
        let fromDevice = try store.record(file(nfd, size: 10), parentId: ItemStore.rootId)
        let stored = try #require(try store.item(id: fromDevice.id))
        #expect(Array(stored.name.utf8) == Array(nfd.utf8))
        #expect(try store.item(path: root.appending(nfc))?.id == first.id)
    }

    @Test("remove deletes the subtree with tombstones for each id")
    func removeSubtree() throws {
        let d = try store.record(dir("d"), parentId: ItemStore.rootId)
        let e = try store.record(dir("d/e"), parentId: d.id)
        let f = try store.record(file("d/e/f"), parentId: e.id)
        let anchor = store.currentGeneration
        try store.remove(id: d.id)
        #expect(Set(try store.changes(since: anchor).deleted) == [d.id, e.id, f.id])
        #expect(try store.item(id: f.id) == nil)
    }

    @Test("a directory replaced by a file drops its children")
    func directoryBecomesFile() throws {
        let d = try store.record(dir("x"), parentId: ItemStore.rootId)
        let child = try store.record(file("x/child"), parentId: d.id)
        let replaced = try store.record(file("x"), parentId: ItemStore.rootId)
        #expect(replaced.id == d.id)
        #expect(replaced.kind == .file)
        #expect(try store.item(id: child.id) == nil)
    }

    @Test("version check guards writes: a device-side change is a conflict")
    func versionGuard() throws {
        let item = try store.record(file("note.txt", size: 5, mtime: 100), parentId: ItemStore.rootId)
        #expect(try store.versionMatches(id: item.id, version: item.version))
        try list(ItemStore.rootId, [file("note.txt", size: 6, mtime: 200)])
        #expect(try !store.versionMatches(id: item.id, version: item.version))
    }

    @Test("data survives reopening the database file")
    func persistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("itemstore-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let id: String
        do {
            let disk = try ItemStore(url: url, root: root)
            id = try disk.record(file("keep.txt"), parentId: ItemStore.rootId).id
        }
        let reopened = try ItemStore(url: url, root: root)
        #expect(try reopened.item(path: root.appending("keep.txt"))?.id == id)
        #expect(reopened.currentGeneration > 0)
    }

    @Test("paths outside the domain root resolve to nothing")
    func outsideRoot() throws {
        #expect(try store.item(path: RemotePath("/data/local")) == nil)
        #expect(try store.item(path: root)?.id == ItemStore.rootId)
    }

    @Test("only listed directories are refreshed, shallowest first")
    func listedDirectories() throws {
        let dcim = try store.record(dir("DCIM"), parentId: ItemStore.rootId)
        let camera = try store.record(dir("DCIM/Camera"), parentId: dcim.id)
        _ = try store.record(dir("Music"), parentId: ItemStore.rootId)
        try list(camera.id, [file("DCIM/Camera/1.jpg")])
        try list(ItemStore.rootId, [dir("DCIM"), dir("Music")])
        #expect(try store.listedDirectories().map(\.id) == [ItemStore.rootId, camera.id])
    }

    @Test("a folder made on the Mac is refreshed although never listed")
    func markListed() throws {
        let made = try store.record(dir("New"), parentId: ItemStore.rootId)
        let note = try store.record(file("note.txt"), parentId: ItemStore.rootId)
        try store.markListed(id: made.id)
        try store.markListed(id: note.id)
        #expect(try store.listedDirectories().map(\.id) == [made.id])
    }

    @Test("10,000 children in batches of 500 stay fast")
    func largeListing() throws {
        let entries = (0..<10_000).map { file(String(format: "file-%05d.txt", $0)) }
        let start = ContinuousClock.now
        let listing = try store.beginListing(of: ItemStore.rootId)
        for batch in stride(from: 0, to: entries.count, by: 500) {
            _ = try store.apply(Array(entries[batch..<batch + 500]), to: listing)
        }
        try store.finishListing(listing)
        #expect(try store.children(of: ItemStore.rootId).count == 10_000)
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
