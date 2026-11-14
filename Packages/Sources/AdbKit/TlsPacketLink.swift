import DroidCore
import Foundation

/// A packet link that can switch its byte stream to TLS when adbd asks for it with
/// STLS (spec §5.4, plan P3-05). `AdbConnection.connect` sends our STLS reply, calls
/// `startTls()`, and then expects the device's CNXN over TLS.
public protocol AdbTlsUpgradable: AdbPacketLink {
    func startTls() async throws
}

/// ADB packets over a `TlsChannel` that starts in plaintext: the link for adbd's
/// wireless-debugging port (`_adb-tls-connect._tcp`).
public actor TlsPacketLink: AdbTlsUpgradable {
    private let channel: TlsChannel
    private var decoder = AdbMessageDecoder()
    private var checksumRequired = true

    public init(channel: TlsChannel) { self.channel = channel }

    public static func connect(host: String, port: UInt16, identity: TlsIdentity) async throws -> TlsPacketLink {
        TlsPacketLink(channel: try await TlsChannel.connectStartTls(host: host, port: port, identity: identity))
    }

    public func send(_ message: AdbMessage) async throws {
        try await channel.write(message.encoded(withChecksum: checksumRequired))
    }

    public func setChecksumRequired(_ required: Bool) { checksumRequired = required }

    public func receive() async throws -> AdbMessage {
        while true {
            if let message = try decoder.next() { return message }
            guard let chunk = try await channel.read() else { throw DeviceError.disconnected }
            decoder.append(chunk)
        }
    }

    public func startTls() async throws { try await channel.startTls() }

    public func close() async { await channel.close() }
}
