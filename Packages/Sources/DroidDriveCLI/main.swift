// droiddrive-cli: drives AdbKit from the terminal. Used for spike S0-b and for
// measuring against `adb` (spec §9). Not shipped in the app.
//
//   droiddrive-cli [--direct HOST:PORT | --server SERIAL] [--key PEM] <command> [args]
//
// Commands: devices, info, storages, ls PATH, stat PATH, pull REMOTE LOCAL,
//           push LOCAL REMOTE, mkdir PATH, rm PATH, mv FROM TO
import AdbKit
import DroidCore
import Foundation

struct Options {
    var direct: (host: String, port: UInt16)?
    var serial: String?
    var keyPath: String?
    var command: [String] = []

    static func parse(_ args: [String]) throws -> Options {
        var options = Options()
        var rest = args[...]
        while let arg = rest.popFirst() {
            switch arg {
            case "--direct":
                guard let value = rest.popFirst(), let colon = value.lastIndex(of: ":"),
                      let port = UInt16(value[value.index(after: colon)...]) else { throw usage }
                options.direct = (String(value[..<colon]), port)
            case "--server":
                guard let value = rest.popFirst() else { throw usage }
                options.serial = value
            case "--key":
                guard let value = rest.popFirst() else { throw usage }
                options.keyPath = value
            default:
                options.command = [arg] + rest
                return options
            }
        }
        throw usage
    }

    static let usage = CLIError("usage: droiddrive-cli [--direct HOST:PORT | --server SERIAL] [--key PEM] devices|info|storages|ls|stat|pull|push|mkdir|rm|mv …")
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

/// Uses adb's own key when it exists (so a device that already trusts `adb` does not
/// prompt again), otherwise DroidDrive's key from the Keychain, created on first use.
func loadKey(_ path: String?) throws -> AdbKey {
    let adbKey = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/adbkey").path
    if let path = path ?? (FileManager.default.fileExists(atPath: adbKey) ? adbKey : nil) {
        return try AdbKey(pem: try String(contentsOfFile: path, encoding: .utf8))
    }
    return try AdbKeyStore().loadOrCreate()
}

func makeTransport(_ options: Options) async throws -> AdbTransport {
    if let direct = options.direct {
        let link = try await TcpPacketLink.connect(host: direct.host, port: direct.port)
        let host = ProcessInfo.processInfo.hostName
        let connection = try await AdbConnection.connect(link: link, key: try loadKey(options.keyPath),
                                                         keyName: "droiddrive@\(host)") { _ in
            FileHandle.standardError.write(Data("Unlock the phone and tap Allow…\n".utf8))
        }
        return try await AdbTransport.connect(connection)
    }
    let server = AdbServerClient()
    let serial: String
    if let given = options.serial {
        serial = given
    } else {
        let ready = try await server.devices().filter { $0.state == "device" }
        guard ready.count == 1 else { throw CLIError("\(ready.count) devices ready; pick one with --server SERIAL") }
        serial = ready[0].serial
    }
    return try await AdbTransport.connect(try await server.opener(serial: serial), fallbackSerial: serial)
}

func formatRate(bytes: UInt64, seconds: Double) -> String {
    String(format: "%.1f MB/s", Double(bytes) / 1_048_576 / max(seconds, 0.001))
}

func run(_ options: Options) async throws {
    let args = options.command
    func arg(_ i: Int) throws -> String {
        guard i < args.count else { throw Options.usage }
        return args[i]
    }
    if args[0] == "devices" {
        for device in try await AdbServerClient().devices() {
            print(device.serial, device.state, device.properties["model"] ?? "")
        }
        return
    }
    let transport = try await makeTransport(options)
    let clock = ContinuousClock()
    switch args[0] {
    case "info":
        print(transport.info)
    case "storages":
        for storage in try await transport.storages() {
            print(storage.displayName(model: transport.info.model), storage.root,
                  "free \(storage.free / 1_048_576) MB of \(storage.capacity / 1_048_576) MB")
        }
    case "ls":
        let start = clock.now
        var count = 0
        var firstBatch: Duration?
        for try await batch in transport.list(RemotePath(exact: try arg(1))) {
            if firstBatch == nil { firstBatch = clock.now - start }
            count += batch.count
            if count <= 50 {
                for entry in batch.prefix(50) { print(entry.kind.rawValue.prefix(1), entry.size, entry.mtime, entry.name) }
            }
        }
        FileHandle.standardError.write(Data("\(count) entries, first page \(firstBatch ?? .zero), total \(clock.now - start)\n".utf8))
    case "stat":
        print(try await transport.stat(RemotePath(exact: try arg(1))))
    case "pull":
        let local = URL(fileURLWithPath: try arg(2))
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let handle = try FileHandle(forWritingTo: local)
        let progress = Progress()
        let start = clock.now
        try await transport.read(RemotePath(exact: try arg(1)), to: handle, range: nil, progress: progress)
        try handle.close()
        let seconds = Double((clock.now - start).components.seconds) + Double((clock.now - start).components.attoseconds) / 1e18
        print("pulled \(progress.completedUnitCount) bytes, \(formatRate(bytes: UInt64(progress.completedUnitCount), seconds: seconds))")
    case "push":
        let local = URL(fileURLWithPath: try arg(1))
        let handle = try FileHandle(forReadingFrom: local)
        let mtime = try FileManager.default.attributesOfItem(atPath: local.path)[.modificationDate] as? Date
        let progress = Progress()
        let start = clock.now
        let entry = try await transport.write(RemotePath(try arg(2)), from: handle, mtime: mtime, progress: progress)
        let seconds = Double((clock.now - start).components.seconds) + Double((clock.now - start).components.attoseconds) / 1e18
        print("pushed \(entry.size) bytes, mtime \(entry.mtime), \(formatRate(bytes: entry.size, seconds: seconds))")
    case "mkdir":
        print(try await transport.mkdir(RemotePath(try arg(1))))
    case "rm":
        try await transport.delete(RemotePath(exact: try arg(1)), recursive: true)
    case "mv":
        print(try await transport.rename(RemotePath(exact: try arg(1)), to: RemotePath(try arg(2))))
    default:
        throw Options.usage
    }
}

do {
    try await run(try Options.parse(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
