import AdbKit
import DroidCore
import Foundation

/// Opens ADB sessions to phones over Wi-Fi (spec §5.4).
///
/// - `connectTls`: Android 11+ wireless debugging, the port the phone advertises as
///   `_adb-tls-connect._tcp` (plan P3-05). Needs a prior pairing, which put our key on
///   the phone; the phone then accepts our TLS certificate without any prompt.
/// - `connectPlain`: Android 10 and earlier after `adb tcpip` (plan P3-01), port 5555,
///   RSA AUTH as over USB.
public struct WifiConnector: Sendable {
    public let key: AdbKey
    public let keyName: String
    public let identity: TlsIdentity

    public init(key: AdbKey, keyName: String, identity: TlsIdentity) {
        self.key = key
        self.keyName = keyName
        self.identity = identity
    }

    /// Builds the TLS identity from `key` (a PKCS#12 round trip, a few ms).
    public init(key: AdbKey, keyName: String = WifiConnector.defaultKeyName) throws {
        self.init(key: key, keyName: keyName, identity: try TlsIdentity(key: key))
    }

    public static var defaultKeyName: String { "droiddrive@\(ProcessInfo.processInfo.hostName)" }

    public func connectTls(host: String, port: UInt16) async throws -> AdbConnection {
        let link = try await TlsPacketLink.connect(host: host, port: port, identity: identity)
        do {
            return try await AdbConnection.connect(link: link, key: key, keyName: keyName)
        } catch {
            await link.close()
            throw error
        }
    }

    public func connectPlain(host: String, port: UInt16 = TcpipSwitch.defaultPort,
                             onAuth: @Sendable (AdbConnection.AuthEvent) -> Void = { _ in }) async throws -> AdbConnection {
        let link = try await TcpPacketLink.connect(host: host, port: port)
        do {
            return try await AdbConnection.connect(link: link, key: key, keyName: keyName, onAuth: onAuth)
        } catch {
            await link.close()
            throw error
        }
    }

    /// A ready `DeviceTransport` for the File Provider layer.
    public func transport(host: String, port: UInt16, tls: Bool = true) async throws -> AdbTransport {
        let connection = tls ? try await connectTls(host: host, port: port) : try await connectPlain(host: host, port: port)
        return try await AdbTransport.connect(connection, fallbackSerial: "\(host):\(port)")
    }
}
