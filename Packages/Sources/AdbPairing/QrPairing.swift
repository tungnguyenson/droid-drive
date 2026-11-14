import CoreGraphics
import CoreImage
import Foundation

/// The QR code shown in "Connect via Wi-Fi" (spec §5.4, plan P3-06, FR-12). The phone
/// scans it under Wireless debugging → "Pair device with QR code", then advertises
/// `_adb-tls-pairing._tcp` under `serviceName`; we find it and pair with `password`.
/// Same format as Android Studio: `WIFI:T:ADB;S:<name>;P:<password>;;`.
public struct QrPairingCode: Equatable, Sendable {
    public let serviceName: String
    /// Secret; never logged.
    public let password: String

    public init(serviceName: String, password: String) {
        self.serviceName = serviceName
        self.password = password
    }

    /// Letters and digits only, so nothing needs escaping in the WIFI: string.
    static let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public static func random() -> QrPairingCode {
        QrPairingCode(serviceName: "droiddrive-" + randomString(10), password: randomString(12))
    }

    static func randomString(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in alphabet.randomElement(using: &generator)! })
    }

    public var payload: String { "WIFI:T:ADB;S:\(serviceName);P:\(password);;" }

    /// Parses a payload (for tests and for reading back what a phone would scan).
    public static func parse(_ payload: String) -> QrPairingCode? {
        guard payload.hasPrefix("WIFI:"), payload.hasSuffix(";;") else { return nil }
        var fields: [String: String] = [:]
        for part in payload.dropFirst(5).dropLast(2).split(separator: ";") {
            guard let colon = part.firstIndex(of: ":") else { return nil }
            fields[String(part[..<colon])] = String(part[part.index(after: colon)...])
        }
        guard fields["T"] == "ADB", let name = fields["S"], let password = fields["P"],
              !name.isEmpty, !password.isEmpty else { return nil }
        return QrPairingCode(serviceName: name, password: password)
    }

    /// The QR code as a crisp image, `scale` pixels per module.
    public func image(scale: CGFloat = 8) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else {
            return nil
        }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
    }
}

extension PairingClient {
    /// Waits for the phone that scanned `code` to advertise itself, then pairs.
    public func pair(qr code: QrPairingCode, timeout: Duration = .seconds(120)) async throws -> PairingResult {
        let service = try await WifiDiscovery.waitFor(.pairing, named: code.serviceName, timeout: timeout)
        guard let host = service.host, let port = service.port else {
            throw WifiPairingError.serviceNotFound(code.serviceName)
        }
        return try await pair(host: host, port: port, code: code.password)
    }

    /// Pairs with a phone found by discovery (the "Pairing code" tab).
    public func pair(service: WifiService, code: String) async throws -> PairingResult {
        guard service.kind == .pairing, let host = service.host, let port = service.port else {
            throw WifiPairingError.serviceNotFound(service.name)
        }
        return try await pair(host: host, port: port, code: code)
    }
}
