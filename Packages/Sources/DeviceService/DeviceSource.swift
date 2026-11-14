import DroidCore
import Foundation

/// How the app reaches a phone: protocol and link (spec §6 "Pixel 8 (ADB · USB)").
public struct ConnectionKind: Hashable, Sendable, Codable {
    public enum Wire: String, Sendable, Codable { case adb, mtp }
    public enum Link: String, Sendable, Codable { case usb, wifi }

    public let wire: Wire
    public let link: Link

    public init(_ wire: Wire, _ link: Link) {
        self.wire = wire
        self.link = link
    }

    public static let adbUSB = ConnectionKind(.adb, .usb)
    public static let adbWiFi = ConnectionKind(.adb, .wifi)
    public static let mtpUSB = ConnectionKind(.mtp, .usb)

    /// "ADB · USB", "ADB · Wi-Fi", "MTP · USB".
    public var label: String {
        "\(wire == .adb ? "ADB" : "MTP") · \(link == .usb ? "USB" : "Wi-Fi")"
    }
}

public enum PhoneState: Hashable, Sendable {
    case ready
    /// Waiting for the user to accept "Allow USB debugging?" on the phone.
    case unauthorized
    case offline
    /// Two different phones report this serial; neither is mounted (spec §5.4).
    case conflict
    /// Another process holds the USB interface (spec §5.7).
    case busy(by: String?)
}

/// One phone as one device source sees it.
public struct DiscoveredPhone: Hashable, Sendable {
    /// The phone's own serial (`ro.serialno`): stable across USB, Wi-Fi and MTP, so it
    /// keys the Finder drives. Before the phone is identified, the connection's own id.
    public let id: String
    public let model: String
    public let connection: ConnectionKind
    public let state: PhoneState
    /// Source-private address of the connection (an adb serial, a USB location id…);
    /// handed back to `makeTransport`. Two phones with the same `id` from one source
    /// differ here.
    public let address: String

    public init(id: String, model: String, connection: ConnectionKind, state: PhoneState, address: String) {
        self.id = id
        self.model = model
        self.connection = connection
        self.state = state
        self.address = address
    }
}

/// A way of finding phones: the user's adb server today; DroidDrive's own USB/ADB,
/// MTP and Wi-Fi (paired ADB over TLS) later. Sources know nothing about XPC or
/// File Provider; `DeviceRegistry` merges them and hands transports to the XPC host.
///
/// To add one: implement this protocol in the package that owns the transport (UsbKit,
/// MtpKit, AdbPairing) or in DeviceService, and pass an instance to `DeviceRegistry`
/// in the app (`DeviceManager.makeRegistry`).
public protocol DeviceSource: Sendable {
    /// Stable id of the source, e.g. "adb-server", "usb", "mtp", "wifi".
    var id: String { get }

    /// Phones reachable now. Called on every poll (every 2 s), so it must be cheap;
    /// a source that gets hot-plug events can return a cached list. Throws when the
    /// source itself is unavailable (adb server not running); the registry then keeps
    /// the other sources' phones.
    func scan() async throws -> [DiscoveredPhone]

    /// Opens a transport to `phone`, one of the phones the last `scan` returned with
    /// `state == .ready`. The registry caches it until the phone disappears or a
    /// device call fails with `DeviceError.disconnected`.
    func makeTransport(for phone: DiscoveredPhone) async throws -> any DeviceTransport
}

/// Gives the XPC host a transport for a phone; `DeviceRegistry` is the real one.
public protocol TransportProvider: Sendable {
    func transport(for phoneId: String) async throws -> any DeviceTransport
    /// Drops a cached transport after it reported the phone gone.
    func invalidate(phoneId: String) async
}
