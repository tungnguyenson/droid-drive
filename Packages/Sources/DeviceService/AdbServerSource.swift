import AdbKit
import DroidCore
import Foundation

/// Phones the user's adb server sees (USB, or Wi-Fi after `adb pair`/`adb connect`),
/// grouped into phones by `ro.serialno` (plan P1-08).
public struct AdbServerSource: DeviceSource {
    public let id = "adb-server"
    private let server: AdbServerClient
    private let directory: DeviceDirectory

    public init(server: AdbServerClient = AdbServerClient()) {
        self.server = server
        directory = DeviceDirectory(server: server)
    }

    public func scan() async throws -> [DiscoveredPhone] {
        try await directory.phones().map { phone in
            Self.discovered(id: phone.id, model: phone.model, state: phone.state,
                            adbSerial: phone.adbSerial, adbSerials: phone.adbSerials)
        }
    }

    public func makeTransport(for phone: DiscoveredPhone) async throws -> any DeviceTransport {
        try await AdbTransport.connect(try await server.opener(serial: phone.address), fallbackSerial: phone.address)
    }

    static func discovered(id: String, model: String, state: Phone.State, adbSerial: String?,
                           adbSerials: [String]) -> DiscoveredPhone {
        let address = adbSerial ?? adbSerials.first ?? id
        let mapped: PhoneState = switch state {
        case .ready: .ready
        case .unauthorized: .unauthorized
        case .offline: .offline
        case .conflict: .conflict
        }
        return DiscoveredPhone(id: id, model: model,
                               connection: DeviceDirectory.isWiFi(address) ? .adbWiFi : .adbUSB,
                               state: mapped, address: address)
    }
}
