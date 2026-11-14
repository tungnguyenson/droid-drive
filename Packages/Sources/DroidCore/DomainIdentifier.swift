import Foundation

/// Identifies one Finder domain: one storage of one device (spec §1 "Domain").
/// Encoded as `<base64url(serial)>.<storage>` so the identifier is a safe file name even
/// for TCP serials like "192.168.1.5:5555"; `storage` is "internal" or the SD card id.
public struct DomainIdentifier: Hashable, Sendable, CustomStringConvertible {
    public static let internalStorage = "internal"

    public let serial: String
    public let storage: String

    public init(serial: String, storage: String) {
        self.serial = serial
        self.storage = storage
    }

    public init(serial: String, storage: StorageInfo) {
        self.init(serial: serial,
                  storage: storage.kind == .internal ? Self.internalStorage : storage.root.name)
    }

    public init?(rawValue: String) {
        guard let dot = rawValue.lastIndex(of: "."),
              let serial = Self.decode(String(rawValue[..<dot])) else { return nil }
        let storage = String(rawValue[rawValue.index(after: dot)...])
        guard !storage.isEmpty, !storage.contains("/") else { return nil }
        self.init(serial: serial, storage: storage)
    }

    public var rawValue: String { "\(Self.encode(serial)).\(storage)" }

    /// Device path of the storage root.
    public var root: RemotePath {
        storage == Self.internalStorage ? RemotePath("/storage/emulated/0") : RemotePath("/storage").appending(exact: storage)
    }

    public var description: String { rawValue }

    private static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ text: String) -> String? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).map { String(decoding: $0, as: UTF8.self) }
    }
}
