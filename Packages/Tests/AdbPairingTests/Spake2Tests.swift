import CSpake2
import DroidCore
import Foundation
import Testing
@testable import AdbPairing

/// SPAKE2 (P3-02). BoringSSL ships no fixed vectors for it, so the known-answer test
/// below comes from an independent pure-Python model of `spake25519.c` (edwards25519
/// arithmetic with Python integers, M and N decoded from the points in that file's
/// comment). The round-trip tests mirror BoringSSL's `spake25519_test.cc`.
@Suite("SPAKE2")
struct Spake2Tests {
    static let password = Data("123456".utf8) + Data((0..<64).map { UInt8($0) })
    static let randomAlice = Data((0..<64).map { UInt8(($0 * 7 + 1) & 0xFF) })
    static let randomBob = Data((0..<64).map { UInt8(($0 * 13 + 5) & 0xFF) })

    static func message(_ role: Spake2.Role, random: Data, password: Data = password) throws -> (Spake2, Data) {
        let alice = role == .alice
        let spake = try Spake2(role: role,
                               myName: alice ? PairingAuth.clientName : PairingAuth.serverName,
                               theirName: alice ? PairingAuth.serverName : PairingAuth.clientName)
        let msg = try random.withUnsafeBytes { raw in
            cspake2_set_test_random(raw.bindMemory(to: UInt8.self).baseAddress)
            return try spake.generateMessage(password: password)
        }
        return (spake, msg)
    }

    @Test("known-answer vector with ADB's names")
    func knownAnswer() throws {
        let (alice, aliceMsg) = try Self.message(.alice, random: Self.randomAlice)
        let (bob, bobMsg) = try Self.message(.bob, random: Self.randomBob)
        #expect(aliceMsg.hex == "bbd98b24adc4889594836c8af5f77d6964b9ba2ee2dbf85836d79a93d5a2df27")
        #expect(bobMsg.hex == "f7341b5734fcc0ec2342960bb519a32e6978b171a12dd49849392ae9e98e3769")
        let expected = "55c45610036c51334424691db21c091b69f7ab38920231d010ebbf5e60d16f8e"
            + "918bef8253d46121385ded0b375b6cbb72a16762aee3bbe17c55056e2d1a0f8e"
        #expect(try alice.processMessage(bobMsg).hex == expected)
        #expect(try bob.processMessage(aliceMsg).hex == expected)
    }

    @Test("random runs agree", arguments: 0..<10)
    func roundTrip(_ run: Int) throws {
        let alice = try PairingAuth(role: .client, password: Data("654321".utf8))
        let bob = try PairingAuth(role: .server, password: Data("654321".utf8))
        #expect(alice.message.count == 32)
        #expect(alice.message != bob.message)
        try alice.initCipher(theirMessage: bob.message)
        try bob.initCipher(theirMessage: alice.message)
        let sealed = try alice.encrypt(Data("hello \(run)".utf8))
        #expect(try bob.decrypt(sealed) == Data("hello \(run)".utf8))
    }

    @Test("a wrong password gives different keys")
    func wrongPassword() throws {
        let alice = try PairingAuth(role: .client, password: Data("111111".utf8))
        let bob = try PairingAuth(role: .server, password: Data("222222".utf8))
        try alice.initCipher(theirMessage: bob.message)
        try bob.initCipher(theirMessage: alice.message)
        #expect(throws: WifiPairingError.wrongCode) { try bob.decrypt(try alice.encrypt(Data([1, 2, 3]))) }
    }

    @Test("mismatched names give different keys")
    func wrongNames() throws {
        let alice = try Spake2(role: .alice, myName: Data("alice".utf8), theirName: Data("charlie".utf8))
        let bob = try Spake2(role: .bob, myName: Data("bob".utf8), theirName: Data("charlie".utf8))
        let a = try alice.generateMessage(password: Data("pw".utf8))
        let b = try bob.generateMessage(password: Data("pw".utf8))
        #expect(try alice.processMessage(b) != bob.processMessage(a))
    }

    @Test("corrupted messages never agree")
    func corrupted() throws {
        for bit in stride(from: 0, to: 256, by: 7) {
            let alice = try Spake2(role: .alice, myName: PairingAuth.clientName, theirName: PairingAuth.serverName)
            let bob = try Spake2(role: .bob, myName: PairingAuth.serverName, theirName: PairingAuth.clientName)
            var a = try alice.generateMessage(password: Self.password)
            let b = try bob.generateMessage(password: Self.password)
            a[bit / 8] ^= 1 << (bit % 8)
            let aliceKey = try alice.processMessage(b)
            if let bobKey = try? bob.processMessage(a) { #expect(aliceKey != bobKey, "bit \(bit)") }
        }
    }

    @Test("generate twice and bad message lengths are refused")
    func misuse() throws {
        let alice = try Spake2(role: .alice, myName: Data("a".utf8), theirName: Data("b".utf8))
        #expect(throws: DeviceError.self) { try alice.processMessage(Data(count: 32)) }
        _ = try alice.generateMessage(password: Data("x".utf8))
        #expect(throws: DeviceError.self) { try alice.generateMessage(password: Data("x".utf8)) }
        #expect(throws: DeviceError.self) { try alice.processMessage(Data(count: 31)) }
        #expect(throws: DeviceError.self) { try PairingAuth(role: .client, password: Data()) }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
