// droiddrive-wifi: exercises the Wi-Fi pairing and TLS code from the terminal (plan
// phase 3). Not shipped in the app.
//
//   droiddrive-wifi [--key PEM] <command>
//
//   discover [SECONDS]          list phones advertising _adb-tls-pairing/_adb-tls-connect
//   pair HOST:PORT CODE         pair with the 6-digit code shown on the phone
//   qr [SECONDS]                print a QR payload, wait for the phone to scan it, pair
//   connect HOST:PORT           TLS connect (after pairing) and print the device info
//   ls HOST:PORT PATH           list a folder over the TLS connection
//   tcpip SERIAL                switch a phone on the adb server to TCP mode and connect
//   serve-pairing CODE          act as a phone's pairing server on 127.0.0.1 (for `adb pair`)
//
// The key is ~/.android/adbkey when it exists (so phones that trust adb trust us too),
// else a DroidDrive key under Application Support, like droiddrive-cli.
import AdbKit
import AdbPairing
import DroidCore
import Foundation

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

let usage = CLIError("usage: droiddrive-wifi [--key PEM] discover|pair|qr|connect|ls|tcpip|serve-pairing …")

func loadKey(_ path: String?) throws -> AdbKey {
    let fm = FileManager.default
    let adbKey = fm.homeDirectoryForCurrentUser.appendingPathComponent(".android/adbkey").path
    if let path = path ?? (fm.fileExists(atPath: adbKey) ? adbKey : nil) {
        return try AdbKey(pem: try String(contentsOfFile: path, encoding: .utf8))
    }
    let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidDrive")
    let file = dir.appendingPathComponent("adbkey.pem")
    if fm.fileExists(atPath: file.path) {
        return try AdbKey(pem: try String(contentsOf: file, encoding: .utf8))
    }
    let key = try AdbKey.generate()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = try key.pkcs1Data().base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    try "-----BEGIN RSA PRIVATE KEY-----\n\(body)\n-----END RSA PRIVATE KEY-----\n"
        .write(to: file, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return key
}

func describe(_ service: WifiService) -> String {
    let address = service.host.map { "\($0):\(service.port.map(String.init) ?? "?")" } ?? "(resolving)"
    return "\(service.kind == .pairing ? "pairing" : "connect")  \(service.name)  \(address)"
}

func discover(seconds: Int) async {
    let deadline = ContinuousClock.now + .seconds(seconds)
    let watcher = Task {
        var last: [WifiService] = []
        for await snapshot in WifiDiscovery.services() where snapshot != last {
            last = snapshot
            print("--- \(snapshot.count) service(s)")
            snapshot.forEach { print(describe($0)) }
        }
    }
    try? await Task.sleep(until: deadline)
    watcher.cancel()
}

func run(_ args: [String]) async throws {
    var rest = args[...]
    var keyPath: String?
    if rest.first == "--key" {
        rest.removeFirst()
        keyPath = rest.popFirst()
    }
    guard let command = rest.popFirst() else { throw usage }
    let words = Array(rest)
    func arg(_ i: Int) throws -> String {
        guard i < words.count else { throw usage }
        return words[i]
    }

    switch command {
    case "discover":
        await discover(seconds: Int(words.first ?? "") ?? 10)
        return
    default:
        break
    }

    let connector = try WifiConnector(key: try loadKey(keyPath))
    switch command {
    case "pair":
        let address = try PairingClient.parseAddress(try arg(0))
        let result = try await PairingClient(connector: connector).pair(host: address.host, port: address.port, code: try arg(1))
        print("Paired. Device GUID: \(result.guid)")
    case "qr":
        let code = QrPairingCode.random()
        print(code.payload)
        print("Scan this with Wireless debugging → Pair device with QR code (render it with any QR tool).")
        let seconds = Int(words.first ?? "") ?? 120
        let result = try await PairingClient(connector: connector).pair(qr: code, timeout: .seconds(seconds))
        print("Paired. Device GUID: \(result.guid)")
    case "connect":
        let address = try PairingClient.parseAddress(try arg(0))
        let transport = try await connector.transport(host: address.host, port: address.port)
        print(transport.info)
    case "ls":
        let address = try PairingClient.parseAddress(try arg(0))
        let transport = try await connector.transport(host: address.host, port: address.port)
        var count = 0
        for try await batch in transport.list(RemotePath(exact: try arg(1))) {
            for entry in batch where count < 50 {
                print(entry.kind.rawValue.prefix(1), entry.size, entry.mtime, entry.name)
                count += 1
            }
        }
    case "tcpip":
        let serial = try arg(0)
        let opener = try await AdbServerClient().opener(serial: serial)
        let address = try await TcpipSwitch.wifiAddress(on: opener)
        print("Wi-Fi address: \(address); switching to TCP mode…")
        let connection = try await TcpipSwitch.switchToWifi(opener: opener, serial: serial, connector: connector,
                                                            store: PairedDeviceStore())
        print(try await AdbTransport.connect(connection, fallbackSerial: "\(address):5555").info)
    case "serve-pairing":
        let server = try PairingServer(code: try arg(0), guid: "adb-DROIDDRIVETEST-\(Int.random(in: 100000...999999))",
                                       identity: connector.identity)
        let port = try await server.start()
        print("Listening on 127.0.0.1:\(port)")
        for await outcome in server.pairings {
            switch outcome {
            case .success(let paired): print("Paired; client sent type \(paired.peerInfo.type): \(paired.peerInfo.text)")
            case .failure(let error): print("Pairing failed: \(error)")
            }
            break
        }
        server.stop()
    default:
        throw usage
    }
}

setvbuf(stdout, nil, _IOLBF, 0) // line-buffered even when piped, for scripts waiting on output
do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch {
    let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    FileHandle.standardError.write(Data("error: \(text)\n".utf8))
    exit(1)
}
