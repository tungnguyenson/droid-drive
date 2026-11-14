import Foundation

/// Pairing failures the UI explains to the user. Transport failures stay `DeviceError`.
public enum WifiPairingError: Error, Equatable, Sendable, LocalizedError {
    /// The phone's data did not decrypt with our key: the code or QR password was
    /// wrong, or the phone already closed that pairing dialog.
    case wrongCode
    /// No answer from the phone in time.
    case timedOut
    /// The phone answered the pairing, but not with its device GUID.
    case unexpectedPeerInfo(type: UInt8)
    /// The phone advertised nothing we could pair or connect with.
    case serviceNotFound(String)
    /// The address the user typed is not `host:port`.
    case invalidAddress(String)

    public var errorDescription: String? {
        switch self {
        case .wrongCode: "Wrong pairing code, or the phone closed the pairing dialog."
        case .timedOut: "The phone did not answer in time. Check that it is on the same Wi-Fi network."
        case .unexpectedPeerInfo(let type): "The phone answered the pairing in an unknown way (type \(type))."
        case .serviceNotFound(let name): "Could not find \(name) on the network."
        case .invalidAddress(let text): "\"\(text)\" is not an address like 192.168.1.23:37123."
        }
    }
}
