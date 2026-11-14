import CSpake2
import DroidCore
import Foundation

/// One run of SPAKE2 (BoringSSL's, vendored in `CSpake2`): both sides derive the same
/// 64-byte key only if they used the same password (plan P3-02, spec §5.4).
///
/// Not thread-safe; one pairing attempt owns it.
final class Spake2 {
    enum Role {
        /// The side that connects (`adb pair`, DroidDrive pairing a phone).
        case alice
        /// The side that listens (the phone).
        case bob
    }

    static let messageSize = Int(CSPAKE2_MAX_MSG_SIZE)
    static let keySize = Int(CSPAKE2_MAX_KEY_SIZE)

    private let context: OpaquePointer

    init(role: Role, myName: Data, theirName: Data) throws(DeviceError) {
        let created = myName.withUnsafeBytes { mine in
            theirName.withUnsafeBytes { theirs in
                CSPAKE2_CTX_new(role == .alice ? cspake2_role_alice : cspake2_role_bob,
                                mine.bindMemory(to: UInt8.self).baseAddress, mine.count,
                                theirs.bindMemory(to: UInt8.self).baseAddress, theirs.count)
            }
        }
        guard let created else { throw .protocolError("Could not start SPAKE2") }
        context = created
    }

    deinit { CSPAKE2_CTX_free(context) }

    /// Our 32-byte message, masked with the password. Call once.
    func generateMessage(password: Data) throws(DeviceError) -> Data {
        var out = [UInt8](repeating: 0, count: Self.messageSize)
        var length = 0
        let ok = password.withUnsafeBytes { pw in
            CSPAKE2_generate_msg(context, &out, &length, out.count,
                                 pw.bindMemory(to: UInt8.self).baseAddress, pw.count)
        }
        guard ok == 1 else { throw .protocolError("SPAKE2 could not create its message") }
        return Data(out.prefix(length))
    }

    /// The shared key from the peer's message. A wrong password still succeeds here;
    /// it shows up as a key that cannot decrypt the peer's data.
    func processMessage(_ theirs: Data) throws(DeviceError) -> Data {
        var key = [UInt8](repeating: 0, count: Self.keySize)
        var length = 0
        let ok = theirs.withUnsafeBytes { msg in
            CSPAKE2_process_msg(context, &key, &length, key.count,
                                msg.bindMemory(to: UInt8.self).baseAddress, msg.count)
        }
        guard ok == 1 else { throw .protocolError("The phone sent an invalid pairing message") }
        defer { key.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return Data(key.prefix(length))
    }
}
