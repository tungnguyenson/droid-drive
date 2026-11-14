// droiddrive-usb: USB and MTP probe for spike S0-a, plan P1-03 and phase 2. Run it with a
// real phone plugged in; it never opens anything but an Android ADB or MTP interface.
//
//   droiddrive-usb list [--all]               phones (or every device), interfaces, holders
//   droiddrive-usb watch                      plug/unplug events until Ctrl-C
//   droiddrive-usb mtp-info                   GetDeviceInfo + OpenSession + storages
//   droiddrive-usb mtp-ls PATH                list a folder over MTP
//   droiddrive-usb mtp-pull REMOTE LOCAL      copy a file from the phone, with speed
//   droiddrive-usb mtp-push LOCAL REMOTE      copy a file to the phone, with speed
//   droiddrive-usb adb-info                   CNXN/AUTH over USB, device banner
//   droiddrive-usb adb-ls PATH                sync LIST over USB
//
// Options: --device SERIAL|REGISTRY-ID  pick a phone when several are plugged in
//          --seize                      ask the current holder to let go (S0-a)
//          --key PEM                    ADB private key (default ~/.android/adbkey)
import AdbKit
import DroidCore
import Foundation
import MtpKit
import UsbKit

struct Options {
    var device: String?
    var seize = false
    var all = false
    var keyPath: String?
    var command: [String] = []

    static func parse(_ args: [String]) throws -> Options {
        var options = Options()
        var rest = args[...]
        while let arg = rest.popFirst() {
            switch arg {
            case "--device":
                guard let value = rest.popFirst() else { throw usage }
                options.device = value
            case "--seize":
                options.seize = true
            case "--all":
                options.all = true
            case "--key":
                guard let value = rest.popFirst() else { throw usage }
                options.keyPath = value
            default:
                options.command.append(arg)
            }
        }
        guard !options.command.isEmpty else { throw usage }
        return options
    }

    static let usage = CLIError("usage: droiddrive-usb [--device SERIAL|ID] [--seize] [--key PEM] list|watch|mtp-info|mtp-ls PATH|mtp-pull REMOTE LOCAL|mtp-push LOCAL REMOTE|adb-info|adb-ls PATH")
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

func hex(_ value: some BinaryInteger, width: Int = 4) -> String {
    String(format: "%0\(width)x", Int(value))
}

// MARK: list / watch

func describe(_ device: UsbDeviceInfo) -> String {
    var lines = ["\(device.displayName)  [\(hex(device.vendorID)):\(hex(device.productID))]  serial \(device.serial ?? "-")  location 0x\(hex(device.locationID, width: 8))  id \(device.registryID)"]
    if device.looksLikeChargingPhone {
        lines.append("    (phone maker, no ADB/MTP interface: set the phone's USB mode to File transfer)")
    }
    for interface in device.interfaces {
        let kind = interface.kind.map { $0.rawValue.uppercased() } ?? "-"
        var line = "    #\(interface.number) class \(hex(interface.interfaceClass, width: 2))/\(hex(interface.interfaceSubclass, width: 2))/\(hex(interface.interfaceProtocol, width: 2))  \(kind)  \"\(interface.name ?? "")\"  id \(interface.registryID)"
        if interface.kind != nil, let holder = UsbRegistry.holder(ofInterface: interface.registryID) {
            line += "  held by \(holder.processName)\(holder.pid.map { " (pid \($0))" } ?? "")"
        }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}

func list(all: Bool) {
    let devices = UsbRegistry.devices()
    let android = all ? devices : devices.filter(UsbWatcher.defaultFilter)
    for device in android { print(describe(device)) }
    print(all ? "\(devices.count) USB device(s)"
              : "\(android.count) Android device(s), \(devices.count - android.count) other USB device(s) not shown (--all)")
}

func watch() async {
    print("Watching USB (Ctrl-C to stop)…")
    for await event in UsbWatcher.events() {
        switch event {
        case .attached(let device): print("+ \(describe(device))")
        case .detached(let id): print("- device \(id) unplugged")
        }
    }
}

// MARK: Picking a phone

func pick(_ options: Options, _ want: (UsbDeviceInfo) -> UsbInterfaceInfo?) throws -> (UsbDeviceInfo, UsbInterfaceInfo) {
    let candidates = UsbRegistry.devices().compactMap { device in want(device).map { (device, $0) } }
    if let selector = options.device {
        guard let match = candidates.first(where: { $0.0.serial == selector || String($0.0.registryID) == selector }) else {
            throw CLIError("no matching interface on device \(selector)")
        }
        return match
    }
    guard candidates.count == 1 else {
        throw CLIError(candidates.isEmpty
                       ? "no phone with that interface; is it plugged in and set to File transfer / USB debugging?"
                       : "\(candidates.count) phones; pick one with --device SERIAL")
    }
    return candidates[0]
}

func openChannels(_ interface: UsbInterfaceInfo, seize: Bool) throws -> UsbInterfaceChannels {
    do {
        return try UsbInterfaceOpener.open(registryID: interface.registryID, seize: seize)
    } catch .exclusiveAccess(let holder) {
        let who = holder.map { "\($0.processName)\($0.pid.map { " (pid \($0))" } ?? "")" } ?? "another process"
        let advice = holder?.advice.message ?? "Quit the app that uses the phone, then try again."
        throw CLIError("interface busy: held by \(who)\n\(advice)\(holder?.advice.stopCommand.map { "\nTry: \($0.joined(separator: " ")), then run again (or add --seize)" } ?? "")")
    } catch {
        throw CLIError("could not open the interface: \(error)")
    }
}

// MARK: MTP

func openMtp(_ options: Options) async throws -> MtpTransport {
    let (device, interface) = try pick(options) { $0.mtpInterface }
    print("Opening \(interface.kind?.rawValue.uppercased() ?? "?") interface #\(interface.number) of \(device.displayName)…")
    let channels = try openChannels(interface, seize: options.seize)
    return try await MtpTransport.open(channels: channels, serial: device.serial)
}

func mtpInfo(_ options: Options) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let transport = try await openMtp(options)
    let info = transport.session.deviceInfo
    print("Session open in \(clock.now - start)")
    print("Manufacturer: \(info.manufacturer)\nModel: \(info.model)\nVersion: \(info.deviceVersion)\nMTP serial: \(info.serialNumber)")
    print("Vendor extension: \(info.vendorExtensionID) \(info.vendorExtensionDescription)")
    print("Operations (\(info.operations.count)): " + info.operations.map { PtpOperation(rawValue: $0).description }.joined(separator: ", "))
    let checks: [(String, Bool)] = [
        ("GetObjectPropList", transport.session.supports(.getObjectPropList)),
        ("GetPartialObject64", transport.session.supports(.getPartialObject64)),
        ("Android edit ops", PtpOperation.editOperations.allSatisfy(transport.session.supports)),
        ("MoveObject", transport.session.supports(.moveObject)),
        ("SetObjectPropValue", transport.session.supports(.setObjectPropValue)),
    ]
    print(checks.map { "\($0.0): \($0.1 ? "yes" : "NO")" }.joined(separator: "  "))
    for storage in try await transport.storages() {
        print("\(storage.displayName(model: info.model))  \(storage.root)  free \(storage.free >> 20) MB of \(storage.capacity >> 20) MB")
    }
    await transport.close()
}

func mtpList(_ options: Options, _ path: String) async throws {
    let transport = try await openMtp(options)
    let clock = ContinuousClock()
    let start = clock.now
    var count = 0
    var firstBatch: Duration?
    for try await batch in transport.list(RemotePath(exact: path)) {
        if firstBatch == nil { firstBatch = clock.now - start }
        for entry in batch.prefix(max(0, 50 - count)) {
            print(entry.kind == .directory ? "d" : "-", entry.size, entry.mtime, entry.name)
        }
        count += batch.count
    }
    FileHandle.standardError.write(Data("\(count) entries, first page \(firstBatch ?? .zero), total \(clock.now - start)\n".utf8))
    await transport.close()
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

func rate(_ bytes: Int64, _ duration: Duration) -> String {
    String(format: "%.1f MB/s", Double(bytes) / 1_048_576 / max(seconds(duration), 0.001))
}

func mtpPull(_ options: Options, _ remote: String, _ local: String) async throws {
    let transport = try await openMtp(options)
    FileManager.default.createFile(atPath: local, contents: nil)
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: local))
    let progress = Progress()
    let clock = ContinuousClock()
    let start = clock.now
    try await transport.read(RemotePath(exact: remote), to: handle, range: nil, progress: progress)
    try handle.close()
    print("pulled \(progress.completedUnitCount) bytes, \(rate(progress.completedUnitCount, clock.now - start))")
    await transport.close()
}

func mtpPush(_ options: Options, _ local: String, _ remote: String) async throws {
    let transport = try await openMtp(options)
    let url = URL(fileURLWithPath: local)
    let handle = try FileHandle(forReadingFrom: url)
    let mtime = try FileManager.default.attributesOfItem(atPath: local)[.modificationDate] as? Date
    let clock = ContinuousClock()
    let start = clock.now
    let entry = try await transport.write(RemotePath(remote), from: handle, mtime: mtime, progress: Progress())
    try handle.close()
    print("pushed \(entry.size) bytes, mtime \(entry.mtime), \(rate(Int64(entry.size), clock.now - start))")
    await transport.close()
}

// MARK: ADB over USB

/// adb's own key when present, so a phone that trusts `adb` does not prompt again.
func loadKey(_ path: String?) throws -> AdbKey {
    let adbKey = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/adbkey").path
    if let path = path ?? (FileManager.default.fileExists(atPath: adbKey) ? adbKey : nil) {
        return try AdbKey(pem: try String(contentsOfFile: path, encoding: .utf8))
    }
    FileHandle.standardError.write(Data("No ~/.android/adbkey; using a new key (the phone will ask to allow it)\n".utf8))
    return try AdbKey.generate()
}

func openAdb(_ options: Options) async throws -> (AdbConnection, UsbDeviceInfo) {
    let (device, interface) = try pick(options) { $0.adbInterface }
    print("Opening ADB interface #\(interface.number) of \(device.displayName)…")
    let channels = try openChannels(interface, seize: options.seize)
    let link = UsbPacketLink(channels: channels)
    let connection = try await AdbConnection.connect(link: link, key: try loadKey(options.keyPath),
                                                     keyName: "droiddrive@\(ProcessInfo.processInfo.hostName)") { _ in
        FileHandle.standardError.write(Data("Unlock the phone and tap Allow…\n".utf8))
    }
    return (connection, device)
}

func adbInfo(_ options: Options) async throws {
    let (connection, _) = try await openAdb(options)
    print("Banner: \(connection.banner.kind)  \(connection.banner.properties.filter { $0.key != "features" })")
    print("Features: \(connection.features.sorted().joined(separator: ","))")
    print("Max payload: \(connection.maxPayload)")
    await connection.close()
}

func adbList(_ options: Options, _ path: String) async throws {
    let (connection, device) = try await openAdb(options)
    let transport = try await AdbTransport.connect(connection, fallbackSerial: device.serial ?? "")
    print(transport.info)
    for try await batch in transport.list(RemotePath(exact: path)) {
        for entry in batch.prefix(50) { print(entry.kind == .directory ? "d" : "-", entry.size, entry.mtime, entry.name) }
    }
    await connection.close()
}

// MARK: Main

func run(_ options: Options) async throws {
    let args = options.command
    func arg(_ i: Int) throws -> String {
        guard i < args.count else { throw Options.usage }
        return args[i]
    }
    switch args[0] {
    case "list": list(all: options.all)
    case "watch": await watch()
    case "mtp-info": try await mtpInfo(options)
    case "mtp-ls": try await mtpList(options, try arg(1))
    case "mtp-pull": try await mtpPull(options, try arg(1), try arg(2))
    case "mtp-push": try await mtpPush(options, try arg(1), try arg(2))
    case "adb-info": try await adbInfo(options)
    case "adb-ls": try await adbList(options, try arg(1))
    default: throw Options.usage
    }
}

setvbuf(stdout, nil, _IOLBF, 0) // line-buffered, so `watch` output shows up at once
do {
    try await run(try Options.parse(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
