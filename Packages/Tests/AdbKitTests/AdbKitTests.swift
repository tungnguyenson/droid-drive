import DroidCore
import Foundation
import Security
import Testing
@testable import AdbKit

enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    static func maliciousNames() throws -> [String] {
        try Data(contentsOf: url("malicious-names.bin"))
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

@Suite("ADB packets")
struct AdbMessageTests {
    @Test("command constants spell their names")
    func fourCCs() {
        let pairs: [(AdbMessage.Command, String)] = [
            (.cnxn, "CNXN"), (.auth, "AUTH"), (.open, "OPEN"), (.okay, "OKAY"),
            (.clse, "CLSE"), (.wrte, "WRTE"), (.stls, "STLS"),
        ]
        for (command, name) in pairs { #expect(fourCCString(command.rawValue) == name) }
    }

    @Test("header layout matches protocol.txt")
    func encodeHeader() throws {
        let message = AdbMessage(.open, 1, 0, Data("sync:\0".utf8))
        let bytes = [UInt8](message.encoded())
        #expect(bytes.count == 24 + 6)
        #expect(Array(bytes[0..<4]) == Array("OPEN".utf8))
        #expect(Array(bytes[4..<8]) == [1, 0, 0, 0])
        #expect(Array(bytes[12..<16]) == [6, 0, 0, 0])
        let checksum = "sync:\0".utf8.reduce(UInt32(0)) { $0 + UInt32($1) }
        var reader = ByteReader(Array(bytes[16..<24]))
        #expect(try reader.read(UInt32.self) == checksum)
        #expect(try reader.read(UInt32.self) == AdbMessage.Command.open.rawValue ^ 0xFFFF_FFFF)
    }

    @Test("decoder reassembles messages split at any byte")
    func decoderSplits() throws {
        let messages = [
            AdbMessage(.cnxn, AdbMessage.version, 4096, Data("device::features=shell_v2".utf8)),
            AdbMessage(.okay, 7, 1),
            AdbMessage(.wrte, 7, 1, Data(repeating: 0xAB, count: 1000)),
        ]
        let wire = messages.reduce(Data()) { $0 + $1.encoded() }
        for chunkSize in [1, 7, 24, 25, 4096] {
            var decoder = AdbMessageDecoder()
            var decoded: [AdbMessage] = []
            var offset = 0
            while offset < wire.count {
                decoder.append(wire.subdata(in: offset..<min(offset + chunkSize, wire.count)))
                offset += chunkSize
                while let message = try decoder.next() { decoded.append(message) }
            }
            #expect(decoded == messages, "chunk size \(chunkSize)")
        }
    }

    @Test("decoder rejects a bad magic and an oversized payload")
    func decoderRejects() {
        var bad = [UInt8](AdbMessage(.okay, 1, 2).encoded())
        bad[20] ^= 0xFF
        #expect(throws: DeviceError.self) { _ = try AdbMessage.decodeHeader(bad) }

        var huge = Data()
        huge.appendLE(AdbMessage.Command.wrte.rawValue)
        huge.appendLE(UInt32(1)); huge.appendLE(UInt32(1))
        huge.appendLE(UInt32(AdbMessage.maxPayload + 1))
        huge.appendLE(UInt32(0)); huge.appendLE(AdbMessage.Command.wrte.rawValue ^ 0xFFFF_FFFF)
        #expect(throws: DeviceError.self) { _ = try AdbMessage.decodeHeader([UInt8](huge)) }
    }

    @Test("device banner exposes properties and features")
    func banner() {
        let banner = DeviceBanner(Data("device::ro.product.name=oriole;ro.product.model=Pixel 6;ro.product.device=oriole;features=shell_v2,cmd,ls_v2\0".utf8))
        #expect(banner.kind == "device")
        #expect(banner.properties["ro.product.model"] == "Pixel 6")
        #expect(banner.features == ["shell_v2", "cmd", "ls_v2"])
    }
}

@Suite("ADB key")
struct AdbKeyTests {
    @Test("public key encoding matches `adb pubkey` byte for byte")
    func matchesAdbPubkey() throws {
        let expected = try Fixture.text("test-adbkey.pub").split(separator: " ")[0]
        for file in ["test-adbkey-pkcs8.pem", "test-adbkey-pkcs1.pem"] {
            let key = try AdbKey(pem: try Fixture.text(file))
            #expect(try key.androidPublicKeyBase64() == String(expected), "\(file)")
        }
    }

    @Test("AUTH payload is base64, space, name, NUL")
    func authPayload() throws {
        let key = try AdbKey(pem: try Fixture.text("test-adbkey-pkcs8.pem"))
        let payload = try key.androidPublicKey(name: "droiddrive@mac")
        #expect(payload.last == 0)
        let text = String(decoding: payload.dropLast(), as: UTF8.self)
        #expect(text.hasSuffix(" droiddrive@mac"))
        let decoded = Data(base64Encoded: String(text.split(separator: " ")[0]))
        #expect(decoded?.count == 524)
    }

    @Test("token signature verifies as PKCS#1 v1.5 over a SHA-1 digest")
    func signs() throws {
        let key = try AdbKey.generate()
        let token = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        let signature = try key.sign(token: token)
        #expect(signature.count == 256)
        var error: Unmanaged<CFError>?
        #expect(SecKeyVerifySignature(key.publicKey, .rsaSignatureDigestPKCS1v15SHA1,
                                      token as CFData, signature as CFData, &error))
    }

    @Test("generated key survives a PKCS#1 round trip")
    func roundTrip() throws {
        let key = try AdbKey.generate()
        let copy = try AdbKey(pkcs1: try key.pkcs1Data())
        #expect(try copy.androidPublicKeyBase64() == key.androidPublicKeyBase64())
    }

    @Test("n0inv is the negated inverse mod 2^32")
    func n0inv() {
        for n0 in [UInt32(1), 3, 0xFFFF_FFFF, 0x1234_5679] {
            #expect(n0 &* AndroidRSAPublicKey.n0inv(n0) == 0xFFFF_FFFF)
        }
    }
}

@Suite("Shell quoting")
struct ShellQuoteTests {
    /// Runs the quoted name through a real POSIX shell and checks it comes back as one
    /// unchanged argument. If quoting were wrong, the name would split, expand or run.
    @Test("every malicious name survives sh as a single literal argument")
    func survivesShell() throws {
        let names = try Fixture.maliciousNames()
        #expect(names.count >= 20)
        for name in names {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' \(ShellQuote.quote(name)); printf '\\n%s' $#", "sh"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(output == name + "\n0", "name: \(name.debugDescription)")
        }
    }

    @Test("quote wraps in single quotes and escapes embedded ones")
    func format() {
        #expect(ShellQuote.quote("a'b") == #"'a'\''b'"#)
        #expect(ShellQuote.quote(RemotePath("/sdcard/x y")) == "'/sdcard/x y'")
    }
}

@Suite("Sync codec")
struct SyncCodecTests {
    @Test("request is id, length, path bytes")
    func request() throws {
        let data = try SyncCodec.request(SyncCodec.list2, "/sdcard/Đà")
        var r = ByteReader(data)
        #expect(fourCCString(try r.read(UInt32.self)) == "LIS2")
        #expect(try r.read(UInt32.self) == UInt32("/sdcard/Đà".utf8.count))
    }

    @Test("paths longer than 1024 bytes are refused before sending")
    func longPath() {
        #expect(throws: DeviceError.self) { _ = try SyncCodec.request(SyncCodec.stat, "/" + String(repeating: "a", count: 1100)) }
    }

    @Test("DNT2 body decodes 64-bit size and mtime")
    func dent2() throws {
        var body = Data()
        body.appendLE(UInt32(0)); body.appendLE(UInt64(1)); body.appendLE(UInt64(2))
        body.appendLE(UInt32(0o100644)); body.appendLE(UInt32(1)); body.appendLE(UInt32(0)); body.appendLE(UInt32(0))
        body.appendLE(UInt64(6 << 30)); body.appendLE(Int64(0)); body.appendLE(Int64(1_700_000_000)); body.appendLE(Int64(0))
        body.appendLE(UInt32(9))
        #expect(body.count == SyncCodec.dent2BodySize)
        let (stat, nameLength) = try SyncCodec.decodeDent2([UInt8](body))
        #expect(stat.size == 6 << 30)
        #expect(stat.mtime == 1_700_000_000)
        #expect(stat.kind == .file)
        #expect(nameLength == 9)
    }

    @Test("errno and FAIL text map to shared errors")
    func errors() {
        let path = RemotePath("/x")
        #expect(SyncCodec.error(errno: 2, path: path) == .notFound(path))
        #expect(SyncCodec.error(errno: 13, path: path) == .permissionDenied(path))
        #expect(SyncCodec.error(failMessage: "secure_mkdirs failed: No space left on device", path: path) == .noSpace(needed: 0, available: 0))
        #expect(SyncCodec.error(failMessage: "open failed: No such file or directory", path: path) == .notFound(path))
    }
}

@Suite("Parsers")
struct ParserTests {
    @Test("df output becomes storages")
    func storages() {
        let text = "/storage/emulated/0\t/dev/fuse 6082880 1520000 4562880 25% /storage/emulated\n"
            + "/storage/1A2B-3C4D\t/dev/block/vold/public:179,1 31154688 100 31154588 1% /mnt/media_rw/1A2B-3C4D\n"
        let storages = AdbTransport.parseStorages(text)
        #expect(storages.count == 2)
        #expect(storages[0].kind == .internal)
        #expect(storages[0].capacity == 6_082_880 * 1024)
        #expect(storages[0].free == 4_562_880 * 1024)
        #expect(storages[1].kind == .removable)
        #expect(storages[1].root == RemotePath("/storage/1A2B-3C4D"))
    }

    @Test("adb server device list")
    func devices() {
        let devices = AdbServerClient.parseDevices("emulator-5554          device product:sdk_gphone64 model:sdk_gphone64_x86_64 device:emu64x transport_id:1\nR5CT unauthorized usb:1-1 transport_id:2\n")
        #expect(devices.count == 2)
        #expect(devices[0].serial == "emulator-5554")
        #expect(devices[0].properties["model"] == "sdk_gphone64_x86_64")
        #expect(devices[1].state == "unauthorized")
    }

    @Test("smart socket request has a 4-hex length prefix")
    func smartSocket() {
        #expect(String(decoding: AdbServerClient.encode("host:version"), as: UTF8.self) == "000chost:version")
    }
}
