import DroidCore
import Foundation

public extension DeviceError {
    /// One sentence for the UI and the transfer log.
    var userMessage: String {
        switch self {
        case .disconnected: "The phone is not connected"
        case .busy(let by): by.map { "The phone is in use by \($0)" } ?? "The phone is in use by another app"
        case .notFound(let path): "\(path.name.isEmpty ? path.string : path.name) is no longer on the phone"
        case .exists(let path): "\(path.name) already exists on the phone"
        case .noSpace(let needed, let available):
            "Not enough space on the phone (needs \(Self.bytes(needed)), \(Self.bytes(available)) free)"
        case .permissionDenied(let path): "Android does not allow access to \(path.string)"
        case .unsupported(let message): message
        case .invalidName(_, let reason): reason
        case .protocolError(let message): "Communication error: \(message)"
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
