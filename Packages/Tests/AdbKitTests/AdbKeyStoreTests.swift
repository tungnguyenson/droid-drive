import DroidCore
import Foundation
import Testing
@testable import AdbKit

/// Uses the login keychain with a per-test service name, removed afterwards.
@Suite("ADB key in the Keychain", .serialized)
struct AdbKeyStoreTests {
    let store = AdbKeyStore(service: "com.droiddrive.tests.adbkey.\(UUID().uuidString)")

    @Test("nothing is stored at first")
    func emptyAtFirst() throws {
        defer { try? store.delete() }
        #expect(try store.load() == nil)
    }

    @Test("a key is created once and the same key comes back")
    func createsOnce() throws {
        defer { try? store.delete() }
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        #expect(try first.pkcs1Data() == second.pkcs1Data())
        #expect(try first.androidPublicKeyBase64() == second.androidPublicKeyBase64())
    }

    @Test("saving replaces the stored key")
    func replaces() throws {
        defer { try? store.delete() }
        _ = try store.loadOrCreate()
        let imported = try AdbKey(pem: Fixture.text("test-adbkey-pkcs1.pem"))
        try store.save(imported)
        #expect(try store.load()?.pkcs1Data() == imported.pkcs1Data())
    }

    @Test("delete removes the key, and deleting twice is fine")
    func deletes() throws {
        _ = try store.loadOrCreate()
        try store.delete()
        try store.delete()
        #expect(try store.load() == nil)
    }

    @Test("a stored key signs tokens the same way as the PEM it came from")
    func signsLikeTheOriginal() throws {
        defer { try? store.delete() }
        let original = try AdbKey(pem: Fixture.text("test-adbkey-pkcs1.pem"))
        try store.save(original)
        let token = Data((0..<20).map { UInt8($0) })
        #expect(try store.load()?.sign(token: token) == original.sign(token: token))
    }
}
