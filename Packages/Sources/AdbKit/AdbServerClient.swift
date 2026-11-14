import DroidCore
import Foundation

/// Talks to an adb server the user already runs (Android Studio, `adb` CLI) on
/// 127.0.0.1:5037 instead of competing with it for the USB interface (spec §5.4).
///
/// Smart-socket requests are a 4-hex-digit length plus the text; the server answers
/// "OKAY" or "FAIL" + 4-hex length + message.
public struct AdbServerClient: Sendable {
    public static let defaultPort: UInt16 = 5037

    public let host: String
    public let port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16 = AdbServerClient.defaultPort) {
        self.host = host
        self.port = port
    }

    public struct Device: Equatable, Sendable {
        public let serial: String
        public let state: String
        public let properties: [String: String]
    }

    /// True when something answers `host:version` on the port.
    public func isRunning() async -> Bool {
        (try? await query("host:version")) != nil
    }

    public func devices() async throws -> [Device] {
        Self.parseDevices(try await query("host:devices-l"))
    }

    /// Opens a service on one device through the server.
    public func opener(serial: String) async throws -> ServerOpener {
        let raw = try await query("host-serial:\(serial):features")
        let features = Set(raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init))
        return ServerOpener(client: self, serial: serial, features: features)
    }

    public struct ServerOpener: AdbServiceOpener {
        let client: AdbServerClient
        public let serial: String
        public let features: Set<String>

        public func open(_ service: String) async throws -> any AdbByteStream {
            let stream = try await TcpStream.connect(host: client.host, port: client.port)
            do {
                let reader = StreamReader(stream)
                try await AdbServerClient.request("host:transport:\(serial)", on: stream, reader: reader)
                try await AdbServerClient.request(service, on: stream, reader: reader)
                return PrefixedStream(stream, prefix: reader.takeBuffered())
            } catch {
                await stream.close()
                throw error
            }
        }
    }

    // MARK: Smart socket

    /// One request whose answer is a length-prefixed string (host:version, devices, features).
    func query(_ request: String) async throws -> String {
        let stream = try await TcpStream.connect(host: host, port: port, timeout: 2)
        defer { Task { await stream.close() } }
        let reader = StreamReader(stream)
        try await Self.request(request, on: stream, reader: reader)
        let length = try Self.hexLength(try await reader.readExactly(4))
        return String(decoding: try await reader.readExactly(length), as: UTF8.self)
    }

    static func encode(_ request: String) -> Data {
        let bytes = Array(request.utf8)
        return Data(String(format: "%04x", bytes.count).utf8) + Data(bytes)
    }

    static func request(_ request: String, on stream: TcpStream, reader: StreamReader) async throws {
        try await stream.write(encode(request))
        let status = String(decoding: try await reader.readExactly(4), as: UTF8.self)
        switch status {
        case "OKAY":
            return
        case "FAIL":
            let length = try hexLength(try await reader.readExactly(4))
            let message = String(decoding: try await reader.readExactly(length), as: UTF8.self)
            if message.contains("not found") || message.contains("offline") { throw DeviceError.disconnected }
            if message.contains("unauthorized") { throw DeviceError.permissionDenied(.root) }
            throw DeviceError.protocolError("adb server: \(message)")
        default:
            throw DeviceError.protocolError("Unexpected adb server reply: \(status)")
        }
    }

    static func hexLength(_ bytes: [UInt8]) throws -> Int {
        guard let value = Int(String(decoding: bytes, as: UTF8.self), radix: 16) else {
            throw DeviceError.protocolError("Invalid hex length")
        }
        return value
    }

    /// `host:devices-l` lines: `<serial> <state> key:value key:value …`.
    static func parseDevices(_ text: String) -> [Device] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { return nil }
            var props: [String: String] = [:]
            for field in fields.dropFirst(2) {
                let kv = field.split(separator: ":", maxSplits: 1)
                if kv.count == 2 { props[String(kv[0])] = String(kv[1]) }
            }
            return Device(serial: fields[0], state: fields[1], properties: props)
        }
    }
}
