import DroidCore
import Foundation
@testable import DeviceService

let fakeSerial = "FAKE0001"
let storageRoot = RemotePath("/storage/emulated/0")

/// Hands out one FakeTransport; counts invalidations.
final class FakeProvider: TransportProvider, @unchecked Sendable {
    let fake: FakeTransport
    private let lock = NSLock()
    private var invalidations = 0

    init(fake: FakeTransport = FakeTransport()) {
        self.fake = fake
    }

    var invalidated: Int { lock.withLock { invalidations } }

    func transport(for phoneId: String) async throws -> any DeviceTransport {
        guard phoneId == fake.info.serial else { throw DeviceError.disconnected }
        return fake
    }

    func invalidate(phoneId: String) async {
        lock.withLock { invalidations += 1 }
    }
}

/// An app (DeviceHost) and an extension (HostLink) joined by a real NSXPCConnection
/// over an anonymous listener, in this process.
final class LinkedPair: @unchecked Sendable {
    let provider: FakeProvider
    let monitor: TransferMonitor
    let link: HostLink
    let listener: DeviceLinkListener
    let host: DeviceHost
    var connection: NSXPCConnection?

    init(provider: FakeProvider = FakeProvider(), waitTimeout: Duration = .seconds(3),
         failFast: TimeInterval = 10, autoConnect: Bool = false) {
        self.provider = provider
        monitor = TransferMonitor(log: TransferLog(url: nil))
        host = DeviceHost(scope: HostScope(serial: fakeSerial, root: storageRoot), provider: provider, monitor: monitor)
        let counter = Counter()
        let box = WeakBox()
        link = HostLink(domainIdentifier: "domain-1", waitTimeout: waitTimeout, failFastWindow: failFast) {
            counter.increment()
            if autoConnect, let pair = box.pair {
                Task { _ = try? await pair.connect() }
            }
        }
        listener = DeviceLinkListener(link: link, requirement: nil)
        self.counter = counter
        box.pair = self
    }

    private let counter: Counter
    var requestCount: Int { counter.value }

    /// What the app does when the extension asks for it.
    @discardableResult
    func connect() async throws -> String {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        self.connection = connection
        return try await host.serve(connection)
    }

    func transport() async throws -> RemoteDeviceTransport {
        try await RemoteDeviceTransport.connect(serial: fakeSerial, link: link)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class WeakBox: @unchecked Sendable {
    weak var pair: LinkedPair?
}

func temporaryFile(_ contents: Data = Data()) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dd-test-\(UUID().uuidString)")
    try contents.write(to: url)
    return url
}

func expectDeviceError(_ expected: DeviceError, _ body: () async throws -> Void) async -> Bool {
    do {
        try await body()
        return false
    } catch let error as DeviceError {
        return error == expected
    } catch {
        return false
    }
}

/// A scripted device source for registry tests.
final class ScriptedSource: DeviceSource, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var phones: [DiscoveredPhone]
    private var failure: Error?
    private var opened = 0
    var transportSerial: String?

    init(id: String, phones: [DiscoveredPhone] = []) {
        self.id = id
        self.phones = phones
    }

    var openCount: Int { lock.withLock { opened } }
    func set(_ phones: [DiscoveredPhone]) { lock.withLock { self.phones = phones } }
    func fail(_ error: Error?) { lock.withLock { failure = error } }

    func scan() async throws -> [DiscoveredPhone] {
        try lock.withLock {
            if let failure { throw failure }
            return phones
        }
    }

    func makeTransport(for phone: DiscoveredPhone) async throws -> any DeviceTransport {
        lock.withLock { opened += 1 }
        let serial = transportSerial ?? phone.id
        return FakeTransport(info: DeviceInfo(serial: serial, manufacturer: "Fake", model: phone.model, androidVersion: "15"))
    }
}

func phone(_ id: String, _ kind: ConnectionKind = .adbUSB, _ state: PhoneState = .ready,
           address: String? = nil, model: String = "Pixel") -> DiscoveredPhone {
    DiscoveredPhone(id: id, model: model, connection: kind, state: state, address: address ?? "\(id)-\(kind.label)")
}
