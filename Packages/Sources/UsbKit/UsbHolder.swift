import Foundation

/// Who holds a USB interface when opening it fails with `kIOReturnExclusiveAccess`
/// (spec §5.7, plan P2-08). IORegistry records it in two places: the interface's
/// `UsbExclusiveOwner` ("pid 2100, ptpcamerad" for a process, a class name such as
/// "AppleUSBHostCompositeDevice" for a kernel driver), and `IOUserClientCreator` on the
/// user clients below it.
public struct UsbHolder: Hashable, Sendable {
    public let pid: Int32?
    public let processName: String

    public init(pid: Int32?, processName: String) {
        self.pid = pid
        self.processName = processName
    }

    /// Parses "pid 2100, ptpcamerad"; any other non-empty text is a kernel driver name.
    public init?(ownerString: String) {
        let text = ownerString.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("pid "), let comma = text.firstIndex(of: ",") {
            let number = text[text.index(text.startIndex, offsetBy: 4)..<comma].trimmingCharacters(in: .whitespaces)
            let name = text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(number), !name.isEmpty else { return nil }
            self.init(pid: pid, processName: name)
        } else {
            self.init(pid: nil, processName: text)
        }
    }

    /// A kernel or DriverKit driver rather than an app.
    public var isDriver: Bool { pid == nil }

    public var isCurrentProcess: Bool { pid == ProcessInfo.processInfo.processIdentifier }

    public var app: KnownHolder { KnownHolder(processName: processName, isDriver: isDriver) }

    public var advice: BusyAdvice { app.advice(processName: processName) }
}

/// Programs known to grab Android phones on a Mac.
public enum KnownHolder: String, Sendable, CaseIterable {
    /// macOS's PTP/MTP camera daemon (Image Capture, Photos import).
    case ptpcamerad
    /// Image Capture, Photos or their older helpers (PTPCamera, mscamerad-xpc, icdd).
    case imageCapture
    case androidFileTransfer
    case openMTP
    case macDroid
    case smartSwitch
    /// The adb server (Android Studio, `adb`) on the ADB interface.
    case adbServer
    case driver
    case other

    init(processName: String, isDriver: Bool) {
        let name = processName.lowercased()
        func has(_ needle: String) -> Bool { name.contains(needle) }
        if has("ptpcamerad") { self = .ptpcamerad }
        else if has("android file transfer") { self = .androidFileTransfer }
        else if has("openmtp") { self = .openMTP }
        else if has("macdroid") { self = .macDroid }
        else if has("smart switch") || has("smartswitch") { self = .smartSwitch }
        else if name == "adb" || has("android studio") || has("studio") && has("android") { self = .adbServer }
        else if has("image capture") || has("ptpcamera") || has("mscamerad") || name == "icdd"
                    || name == "photos" || has("photolibrary") { self = .imageCapture }
        else if isDriver { self = .driver }
        else { self = .other }
    }

    /// The suggestion the UI shows next to "In use by …" (spec §5.7).
    public func advice(processName: String) -> BusyAdvice {
        switch self {
        case .ptpcamerad:
            return BusyAdvice(
                message: "macOS's photo import service (ptpcamerad) is using the phone. DroidDrive can stop it and try again. If macOS takes the phone back, turn on USB debugging and use ADB instead.",
                stopCommand: ["/usr/bin/killall", "ptpcamerad"], suggestsADB: true)
        case .imageCapture:
            return BusyAdvice(message: "\(processName) is importing photos from the phone. Quit Image Capture and Photos, then try again.",
                              stopCommand: nil, suggestsADB: true)
        case .androidFileTransfer:
            return BusyAdvice(message: "Android File Transfer is using the phone. Quit it, and quit Android File Transfer Agent in the menu bar so it does not reopen.",
                              stopCommand: nil, suggestsADB: false)
        case .openMTP:
            return BusyAdvice(message: "OpenMTP is using the phone. Quit OpenMTP, then try again.", stopCommand: nil, suggestsADB: false)
        case .macDroid:
            return BusyAdvice(message: "MacDroid is using the phone. Quit MacDroid, then try again.", stopCommand: nil, suggestsADB: false)
        case .smartSwitch:
            return BusyAdvice(message: "Samsung Smart Switch is using the phone. Quit Smart Switch, then try again.", stopCommand: nil, suggestsADB: false)
        case .adbServer:
            return BusyAdvice(message: "The adb server (Android Studio or adb) holds the phone's USB debugging connection. DroidDrive talks to the phone through it.",
                              stopCommand: nil, suggestsADB: false)
        case .driver:
            return BusyAdvice(message: "A macOS driver (\(processName)) holds this connection. Unplug the phone and plug it in again.",
                              stopCommand: nil, suggestsADB: true)
        case .other:
            return BusyAdvice(message: "\(processName) is using the phone. Quit it, then try again.", stopCommand: nil, suggestsADB: false)
        }
    }
}

/// What the UI suggests for a busy phone.
public struct BusyAdvice: Hashable, Sendable {
    public let message: String
    /// A command the "Try again" button may run first (only for a daemon that runs as
    /// the user and restarts on demand), as an argv.
    public let stopCommand: [String]?
    /// When MTP keeps failing, ADB is the way around it.
    public let suggestsADB: Bool
}

/// Automatic retry for a busy interface (spec §5.7: every 3 seconds for 30 seconds).
public enum BusyRetry {
    public static let interval: Duration = .seconds(3)
    public static let limit: Duration = .seconds(30)

    /// Runs `body` until it does not fail with `exclusiveAccess`, or `limit` passes;
    /// `onBusy` sees each holder so the UI can show it while waiting.
    public static func run<T: Sendable>(interval: Duration = interval, limit: Duration = limit,
                                        onBusy: @Sendable (UsbHolder?) -> Void = { _ in },
                                        _ body: @Sendable () async throws -> T) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while true {
            do {
                return try await body()
            } catch UsbError.exclusiveAccess(let holder) {
                onBusy(holder)
                guard clock.now + interval <= deadline else { throw UsbError.exclusiveAccess(holder) }
                try await Task.sleep(for: interval)
            }
        }
    }
}
