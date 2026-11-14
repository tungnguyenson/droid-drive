import Foundation

/// What the app exports to the File Provider extension (spec §5.1, plan P1-11).
///
/// Every message is a JSON `HostRequest` / `ReadRequest` / `WriteRequest` answered by a
/// JSON `HostReply`. File contents travel as file descriptors: the extension creates the
/// file (in `NSFileProviderManager.temporaryDirectoryURL()` or the URL macOS handed it)
/// and passes a `FileHandle`; the app reads from it or writes into it.
@objc public protocol DeviceHostXPC {
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Writes the phone file into `file` from its current offset.
    func read(_ request: Data, into file: FileHandle, reply: @escaping @Sendable (Data) -> Void)
    /// Sends `file` (offset 0 to EOF) to the phone.
    func write(_ request: Data, from file: FileHandle, reply: @escaping @Sendable (Data) -> Void)
}

/// What the extension exports back to the app on the same connection.
@objc public protocol DeviceClientXPC {
    /// Sent by the app right after connecting: the extension accepts a connection only
    /// on its first message, and answers with the domain it serves.
    func ping(reply: @escaping @Sendable (String) -> Void)
    func transferProgress(_ transferId: String, completed: Int64, total: Int64)
}

public enum DeviceLink {
    /// `NSFileProviderServiceName` of the extension's service source.
    public static let serviceName = "dev.droiddrive.device-link"

    /// Darwin notification the extension posts when it needs the app to connect to the
    /// domain `domainIdentifier`. Prefixed with the app group so the sandbox allows it.
    public static func linkRequestNotification(appGroup: String, domainIdentifier: String) -> String {
        "\(appGroup).link-request.\(domainIdentifier)"
    }

    /// Code signing requirement the extension sets on the app's connection, so only
    /// DroidDrive.app signed by the same team can act as the device host. nil (no check)
    /// when the build is unsigned.
    public static func hostRequirement(appBundleId: String, teamId: String) -> String? {
        guard !teamId.isEmpty, !appBundleId.isEmpty else { return nil }
        return "identifier \"\(appBundleId)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamId)\""
    }
}
