import Foundation

/// File name rules shared by every transport (spec §5.6).
public enum FileName {
    /// Characters Android rejects in names on shared storage (FAT/exFAT/sdcardfs rules).
    public static let forbiddenCharacters: Set<Character> = ["\"", "*", "/", ":", "<", ">", "?", "\\", "|"]

    /// Suffix added to the Mac copy when a conflict keeps both versions (spec §5.5).
    public static let conflictSuffix = " (Mac copy)"

    /// Converts to NFC. Every name sent to the device goes through this.
    public static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// Two names refer to the same file when their NFC forms are equal.
    public static func same(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    /// Returns the NFC form of `name`, or throws `invalidName` with a reason the UI can
    /// show. Never renames silently.
    public static func validate(_ name: String) throws(DeviceError) -> String {
        let nfc = normalized(name)
        if nfc.isEmpty || nfc == "." || nfc == ".." {
            throw .invalidName(name, reason: "Invalid file name")
        }
        if nfc.contains("\0") || nfc.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            throw .invalidName(name, reason: "File name contains control characters")
        }
        if let bad = nfc.first(where: { forbiddenCharacters.contains($0) }) {
            throw .invalidName(name, reason: "Android does not allow the character \(bad) in file names")
        }
        if nfc.utf8.count > 255 {
            throw .invalidName(name, reason: "File name is longer than 255 bytes")
        }
        return nfc
    }

    /// "Name.ext" → "Name (Mac copy).ext"; a name without extension gets the suffix
    /// at the end. Hidden files (".bashrc") keep the leading dot as part of the stem.
    /// `attempt` 2, 3… gives "Name (Mac copy 2).ext" when the first name is taken too.
    public static func conflictName(for name: String, attempt: Int = 1) -> String {
        let nfc = normalized(name)
        let suffix = attempt <= 1 ? conflictSuffix : " (Mac copy \(attempt))"
        guard let dot = nfc.lastIndex(of: "."), dot != nfc.startIndex else {
            return nfc + suffix
        }
        return String(nfc[..<dot]) + suffix + String(nfc[dot...])
    }
}
