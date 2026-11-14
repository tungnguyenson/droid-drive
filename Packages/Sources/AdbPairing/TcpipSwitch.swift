import AdbKit
import DroidCore
import Foundation
import os

/// "Switch to Wi-Fi" for a phone on the cable, and the only Wi-Fi path for Android 10
/// and earlier (spec §5.4, plan P3-01, FR-14): read the phone's Wi-Fi address, send
/// the `tcpip:5555` service so adbd restarts listening on TCP, then connect to
/// `<ip>:5555` with the usual RSA AUTH. The cable may be unplugged afterwards.
public enum TcpipSwitch {
    public static let defaultPort: UInt16 = 5555
    private static let logger = Logger(subsystem: "com.droiddrive", category: "wifi")

    /// The address to connect to after switching. Read before the switch: adbd
    /// restarts, which drops the USB session.
    public static func wifiAddress(on opener: any AdbServiceOpener) async throws -> String {
        let result = try await opener.runShell("ip -f inet addr show wlan0; ip route")
        guard let address = parseAddress(result.stdoutText) else {
            throw DeviceError.unsupported("The phone is not on Wi-Fi")
        }
        return address
    }

    /// First `inet a.b.c.d/nn` (from `ip addr show wlan0`), else the `src a.b.c.d` of a
    /// route on wlan* (from `ip route`). Loopback is never an answer.
    static func parseAddress(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: \.isWhitespace)
            if let i = words.firstIndex(of: "inet"), i + 1 < words.count {
                let ip = String(words[i + 1].split(separator: "/")[0])
                if isUsableIPv4(ip) { return ip }
            }
        }
        for line in text.split(separator: "\n") where line.contains("dev wlan") {
            let words = line.split(whereSeparator: \.isWhitespace)
            if let i = words.firstIndex(of: "src"), i + 1 < words.count, isUsableIPv4(String(words[i + 1])) {
                return String(words[i + 1])
            }
        }
        return nil
    }

    static func isUsableIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return parts[0] != "127" && parts[0] != "0"
    }

    /// Sends `tcpip:<port>`. adbd answers "restarting in TCP mode port: 5555" and restarts.
    public static func enable(on opener: any AdbServiceOpener, port: UInt16 = defaultPort) async throws {
        let stream = try await opener.open("tcpip:\(port)")
        var reply = Data()
        while reply.count < 256, let chunk = try? await stream.read() { reply.append(chunk) }
        await stream.close()
        let text = String(decoding: reply, as: UTF8.self)
        logger.info("tcpip reply: \(text, privacy: .public)")
        guard text.isEmpty || text.contains("restarting") else {
            throw DeviceError.protocolError("The phone refused TCP mode: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Reads the address, switches, then connects over TCP (retrying while adbd
    /// restarts) and remembers the phone in `store`.
    public static func switchToWifi(opener: any AdbServiceOpener, serial: String, connector: WifiConnector,
                                    store: PairedDeviceStore? = nil, port: UInt16 = defaultPort,
                                    attempts: Int = 10) async throws -> AdbConnection {
        let address = try await wifiAddress(on: opener)
        try await enable(on: opener, port: port)
        var lastError: Error = DeviceError.disconnected
        for _ in 0..<attempts {
            try await Task.sleep(for: .seconds(1))
            do {
                let connection = try await connector.connectPlain(host: address, port: port)
                try? await store?.upsert(PairedDevice(id: serial, serial: serial, kind: .tcpip,
                                                      lastHost: address, lastPort: port))
                return connection
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
