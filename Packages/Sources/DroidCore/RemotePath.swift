import Foundation

/// An absolute POSIX path on the device (spec §5.6).
///
/// Names made on the Mac (often NFD) are converted to NFC before they reach the device;
/// names read from the device keep their bytes so they can be addressed again.
public struct RemotePath: Hashable, Sendable, CustomStringConvertible, Comparable {
    public let string: String

    /// Creates a path from an absolute string typed or built on the Mac, converted to
    /// NFC. Collapses duplicate slashes and a trailing slash; does not resolve `.` or `..`
    /// (those are rejected by `FileName`).
    public init(_ raw: String) {
        self.init(exact: raw.precomposedStringWithCanonicalMapping)
    }

    /// Keeps the bytes as given. Use for names that came from the device: a file an
    /// Android app created with an NFD name must be addressed with those exact bytes.
    /// (Swift's `String ==` compares canonically, so the bytes are checked via `.utf8`.)
    public init(exact raw: String) {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
        self.string = "/" + parts.joined(separator: "/")
    }

    public static let root = RemotePath("/")

    public var isRoot: Bool { string == "/" }

    /// Last path component; empty for the root.
    public var name: String {
        guard !isRoot else { return "" }
        return String(string[string.index(after: string.lastIndex(of: "/")!)...])
    }

    /// Parent directory; the root is its own parent.
    public var parent: RemotePath {
        guard !isRoot, let slash = string.lastIndex(of: "/") else { return self }
        return slash == string.startIndex ? .root : RemotePath(exact: String(string[..<slash]))
    }

    /// Appends one component typed or created on the Mac, converted to NFC. The parent
    /// keeps its bytes. The caller validates `name` with `FileName.validate` first.
    public func appending(_ name: String) -> RemotePath {
        appending(exact: name.precomposedStringWithCanonicalMapping)
    }

    /// Appends a component exactly as the device reported it.
    public func appending(exact name: String) -> RemotePath {
        RemotePath(exact: isRoot ? "/" + name : string + "/" + name)
    }

    /// True when `self` equals `ancestor` or lies below it.
    public func isDescendant(of ancestor: RemotePath) -> Bool {
        ancestor.isRoot || string == ancestor.string || string.hasPrefix(ancestor.string + "/")
    }

    /// Rebases `self` from `old` to `new` (used when a directory is renamed or moved).
    public func replacingPrefix(_ old: RemotePath, with new: RemotePath) -> RemotePath {
        guard isDescendant(of: old) else { return self }
        if string == old.string { return new }
        let suffix = old.isRoot ? String(string.dropFirst()) : String(string.dropFirst(old.string.count + 1))
        return new.appending(exact: suffix)
    }

    public var description: String { string }

    public static func < (lhs: RemotePath, rhs: RemotePath) -> Bool { lhs.string < rhs.string }
}
