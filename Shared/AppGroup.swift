import Foundation

/// Values shared by the app and the File Provider extension (spec §8).
enum AppGroup {
    /// `<TEAMID>.com.droiddrive`, written into both Info.plists at build time.
    static let identifier: String = Bundle.main.object(forInfoDictionaryKey: "DroidDriveAppGroup") as? String ?? ""

    /// Team that signed the build (`DEVELOPMENT_TEAM`), "" for unsigned builds.
    static let teamIdentifier: String = Bundle.main.object(forInfoDictionaryKey: "DroidDriveTeamID") as? String ?? ""

    /// Bundle id of DroidDrive.app; the extension accepts the device link only from it.
    static let hostBundleIdentifier: String =
        Bundle.main.object(forInfoDictionaryKey: "DroidDriveHostBundleID") as? String ?? ""

    /// Shared container; falls back to this process's own Application Support when the
    /// group is not provisioned (unsigned local builds), so nothing crashes.
    static var containerURL: URL {
        if !identifier.isEmpty,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidDrive", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// One SQLite ItemStore per Finder domain.
    static func itemStoreURL(domainIdentifier: String) -> URL {
        let dir = containerURL.appendingPathComponent("ItemStores", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(domainIdentifier).sqlite")
    }

    /// Transfer history, one JSON line per transfer (spec FR-17).
    static var transferLogURL: URL {
        containerURL.appendingPathComponent("TransferLog", isDirectory: true)
            .appendingPathComponent("transfers.jsonl")
    }

    /// Deletes a domain's ItemStore with its WAL files; for drives that will not come back.
    static func removeItemStore(domainIdentifier: String) {
        let url = itemStoreURL(domainIdentifier: domainIdentifier)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
