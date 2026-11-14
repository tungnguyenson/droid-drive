import AdbKit
import DroidCore
import Foundation
import os

/// What a successful pairing tells us about the phone.
public struct PairingResult: Equatable, Sendable {
    /// The phone's device GUID: the `_adb-tls-connect._tcp` name it will advertise.
    public let guid: String
    public let host: String
    public let port: UInt16
}

/// Pairs this Mac with a phone in "Wireless debugging" (spec §5.4, plan P3-03): TLS 1.3
/// to the pairing port, SPAKE2 with the 6-digit code (or the QR password), then our
/// public key goes to the phone, which trusts it from then on.
public struct PairingClient: Sendable {
    public let connector: WifiConnector
    private static let logger = Logger(subsystem: "com.droiddrive", category: "pairing")

    public init(connector: WifiConnector) { self.connector = connector }

    /// `code` is the 6 digits shown on the phone, or the password from our QR code.
    /// Never logged.
    public func pair(host: String, port: UInt16, code: String, timeout: TimeInterval = 15) async throws -> PairingResult {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw DeviceError.protocolError("The pairing code is empty") }
        let channel = try await TlsChannel.connect(host: host, port: port, identity: connector.identity, timeout: timeout)
        let timedOut = Flag()
        let timer = Task {
            try await Task.sleep(for: .seconds(timeout))
            timedOut.set()
            await channel.close()
        }
        defer {
            timer.cancel()
            Task { await channel.close() }
        }
        let ourInfo = try PeerInfo.publicKey("\(try connector.key.androidPublicKeyBase64()) \(connector.keyName)")
        let theirs: PeerInfo
        do {
            theirs = try await PairingSession(channel: TlsPairingChannel(channel), role: .client)
                .run(code: Data(trimmed.utf8), ourInfo: ourInfo)
        } catch {
            if timedOut.isSet { throw WifiPairingError.timedOut }
            throw error
        }
        guard theirs.kind == .deviceGuid, !theirs.text.isEmpty else {
            throw WifiPairingError.unexpectedPeerInfo(type: theirs.type)
        }
        Self.logger.info("Paired with \(theirs.text, privacy: .public) at \(host, privacy: .public):\(port)")
        return PairingResult(guid: theirs.text, host: host, port: port)
    }

    /// Parses "192.168.1.23:37123" or "[fe80::1%en0]:37123".
    public static func parseAddress(_ text: String) throws -> (host: String, port: UInt16) {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port > 0, !host.isEmpty else {
                throw WifiPairingError.invalidAddress(text)
            }
            return (host, port)
        }
        guard let colon = value.lastIndex(of: ":"), value.firstIndex(of: ":") == colon,
              let port = UInt16(value[value.index(after: colon)...]), port > 0 else {
            throw WifiPairingError.invalidAddress(text)
        }
        let host = String(value[..<colon])
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { throw WifiPairingError.invalidAddress(text) }
        return (host, port)
    }
}
