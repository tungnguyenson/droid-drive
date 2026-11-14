import DroidCore
import Foundation

/// Who a phone is, independent of how it is connected. adb names a connection, not a
/// phone: the same phone is "R5CT20ABCDE" over USB, "192.168.1.23:41234" over Wi-Fi
/// (the port changes each time wireless debugging is switched on) and
/// "adb-R5CT20ABCDE-xYz._adb-tls-connect._tcp" through mDNS. Finder drives are keyed by
/// `serial` (`ro.serialno`) so they survive all of these.
public struct DeviceIdentity: Hashable, Sendable {
    /// `ro.serialno`, or the adb serial when the phone reports none.
    public let serial: String
    /// `settings get secure android_id`, "" when unreadable. Only used to tell apart two
    /// phones that report the same serial (some cheap phones ship "0123456789ABCDEF").
    public let androidId: String

    public init(serial: String, androidId: String) {
        self.serial = serial
        self.androidId = androidId
    }

    static let script = "getprop ro.serialno; settings get secure android_id 2>/dev/null"

    public static func read(on opener: any AdbServiceOpener, adbSerial: String) async throws -> DeviceIdentity {
        parse(try await ShellRunner.run(script, on: opener).stdoutText, adbSerial: adbSerial)
    }

    static func parse(_ text: String, adbSerial: String) -> DeviceIdentity {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let serial = lines.first.flatMap { $0.isEmpty ? nil : $0 } ?? adbSerial
        let id = lines.count > 1 && lines[1] != "null" ? lines[1] : ""
        return DeviceIdentity(serial: serial, androidId: id)
    }
}

/// One phone as the app shows it: every adb connection that leads to it, grouped.
public struct Phone: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case ready
        case unauthorized   // the "Allow USB debugging?" prompt is not yet accepted
        case offline
        /// Two different phones report this serial; neither is mounted, since a write
        /// could land on the wrong one.
        case conflict
    }

    /// `DeviceIdentity.serial` once known; before that (unauthorized, offline) the adb serial.
    public let id: String
    public let model: String
    public let state: State
    /// The connection to use: USB before Wi-Fi. nil unless `state == .ready`.
    public let adbSerial: String?
    /// Every adb serial of this phone, ready or not.
    public let adbSerials: [String]
}

/// Maps adb connections to phones, through the user's adb server (plan P1-08).
/// Reading an identity costs one shell call, so it is cached per adb serial and dropped
/// when that connection goes away.
public actor DeviceDirectory {
    public typealias IdentityReader = @Sendable (_ adbSerial: String) async throws -> DeviceIdentity

    private let listDevices: @Sendable () async throws -> [AdbServerClient.Device]
    private let readIdentity: IdentityReader
    private var identities: [String: DeviceIdentity] = [:]

    public init(server: AdbServerClient = AdbServerClient()) {
        self.init(listDevices: { try await server.devices() },
                  readIdentity: { serial in
                      try await DeviceIdentity.read(on: try await server.opener(serial: serial), adbSerial: serial)
                  })
    }

    init(listDevices: @escaping @Sendable () async throws -> [AdbServerClient.Device], readIdentity: @escaping IdentityReader) {
        self.listDevices = listDevices
        self.readIdentity = readIdentity
    }

    /// Throws when the adb server does not answer.
    public func phones() async throws -> [Phone] {
        let devices = try await listDevices()
        let ready = Set(devices.filter { $0.state == "device" }.map(\.serial))
        identities = identities.filter { ready.contains($0.key) }
        var known: [String: DeviceIdentity] = [:]
        for serial in ready.sorted() {
            if let cached = identities[serial] {
                known[serial] = cached
            } else if let identity = try? await readIdentity(serial) {
                identities[serial] = identity
                known[serial] = identity
            }
            // Unreadable this time (phone busy booting): shown as offline, retried next poll.
        }
        return Self.group(devices, identities: known)
    }

    /// The adb serial to reach the phone `id` through right now.
    public func adbSerial(for id: String) async throws -> String {
        guard let phone = try await phones().first(where: { $0.id == id }) else { throw DeviceError.disconnected }
        switch phone.state {
        case .ready: return phone.adbSerial!
        case .conflict: throw DeviceError.busy(by: "another phone with the same serial number")
        case .unauthorized, .offline: throw DeviceError.disconnected
        }
    }

    static func group(_ devices: [AdbServerClient.Device], identities: [String: DeviceIdentity]) -> [Phone] {
        var order: [String] = []
        var members: [String: [AdbServerClient.Device]] = [:]
        for device in devices {
            let ready = device.state == "device" && identities[device.serial] != nil
            let key = ready ? identities[device.serial]!.serial : device.serial
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(device)
        }
        return order.map { key in
            let all = members[key]!
            let ready = all.filter { $0.state == "device" && identities[$0.serial] != nil }
                .sorted { isWiFi($0.serial) == isWiFi($1.serial) ? $0.serial < $1.serial : !isWiFi($0.serial) }
            let model = (all.lazy.compactMap { $0.properties["model"] }.first ?? key).replacingOccurrences(of: "_", with: " ")
            let androidIds = Set(ready.compactMap { identities[$0.serial]?.androidId }.filter { !$0.isEmpty })
            let state: Phone.State
            if androidIds.count > 1 {
                state = .conflict
            } else if !ready.isEmpty {
                state = .ready
            } else if all.contains(where: { $0.state == "unauthorized" }) {
                state = .unauthorized
            } else {
                state = .offline
            }
            return Phone(id: key, model: model, state: state,
                         adbSerial: state == .ready ? ready.first?.serial : nil,
                         adbSerials: all.map(\.serial))
        }
    }

    /// Wi-Fi connections: "host:port" or an mDNS service name.
    public static func isWiFi(_ adbSerial: String) -> Bool {
        if adbSerial.contains("._adb-tls-connect.") || adbSerial.contains("._adb._tcp") { return true }
        guard let colon = adbSerial.lastIndex(of: ":") else { return false }
        let port = adbSerial[adbSerial.index(after: colon)...]
        return !port.isEmpty && port.allSatisfy(\.isNumber)
    }
}
