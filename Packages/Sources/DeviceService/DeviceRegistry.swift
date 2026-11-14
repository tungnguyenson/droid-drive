import DroidCore
import Foundation

/// One phone after merging every source that sees it.
public struct RegisteredPhone: Hashable, Sendable {
    /// The connection used for file access (the preferred ready one).
    public let phone: DiscoveredPhone
    public let sourceId: String
    /// Every connection that leads to this phone, preferred first.
    public let connections: [ConnectionKind]

    public var id: String { phone.id }
}

public struct RegistrySnapshot: Equatable, Sendable {
    public let phones: [RegisteredPhone]
    /// Sources whose scan failed this time, with the error text.
    public let failedSources: [String: String]

    public init(phones: [RegisteredPhone], failedSources: [String: String]) {
        self.phones = phones
        self.failedSources = failedSources
    }
}

/// Holds the device sources and the open transports (spec §5.1: the app owns device
/// connections; the extension only borrows them over XPC).
public actor DeviceRegistry: TransportProvider {
    private let sources: [any DeviceSource]
    private var preferMTP: Bool
    private var snapshot = RegistrySnapshot(phones: [], failedSources: [:])
    private var cached: [String: (key: String, transport: any DeviceTransport)] = [:]
    private var opening: [String: (key: String, task: Task<any DeviceTransport, Error>)] = [:]

    public init(sources: [any DeviceSource], preferMTP: Bool = false) {
        self.sources = sources
        self.preferMTP = preferMTP
    }

    /// Spec §7 "Preferred mode when both MTP and ADB are available": ADB by default.
    public func setPreferMTP(_ value: Bool) {
        preferMTP = value
    }

    public var current: RegistrySnapshot { snapshot }

    /// Scans every source and merges phones by id. Drops transports of phones that are
    /// gone or now reached through another connection.
    @discardableResult
    public func refresh() async -> RegistrySnapshot {
        var found: [(sourceId: String, phone: DiscoveredPhone)] = []
        var failed: [String: String] = [:]
        for source in sources {
            do {
                found += try await source.scan().map { (source.id, $0) }
            } catch {
                failed[source.id] = String(describing: error)
            }
        }
        snapshot = RegistrySnapshot(phones: Self.merge(found, preferMTP: preferMTP), failedSources: failed)
        let liveKeys = Dictionary(uniqueKeysWithValues: snapshot.phones.compactMap { phone in
            phone.phone.state == .ready ? (phone.id, Self.key(phone)) : nil
        })
        cached = cached.filter { liveKeys[$0.key] == $0.value.key }
        return snapshot
    }

    public func transport(for phoneId: String) async throws -> any DeviceTransport {
        var registered = snapshot.phones.first { $0.id == phoneId }
        if registered == nil {
            await refresh()
            registered = snapshot.phones.first { $0.id == phoneId }
        }
        guard let registered else { throw DeviceError.disconnected }
        switch registered.phone.state {
        case .ready: break
        case .conflict: throw DeviceError.busy(by: "another phone with the same serial number")
        case .busy(let by): throw DeviceError.busy(by: by)
        case .unauthorized, .offline: throw DeviceError.disconnected
        }
        let key = Self.key(registered)
        if let hit = cached[phoneId], hit.key == key { return hit.transport }
        if let pending = opening[phoneId], pending.key == key { return try await pending.task.value }

        guard let source = sources.first(where: { $0.id == registered.sourceId }) else {
            throw DeviceError.disconnected
        }
        let phone = registered.phone
        let task = Task<any DeviceTransport, Error> {
            let transport = try await source.makeTransport(for: phone)
            // Never hand out a transport to a phone other than the one asked for (spec §5.4).
            guard transport.info.serial == phone.id else { throw DeviceError.disconnected }
            return transport
        }
        opening[phoneId] = (key, task)
        defer { if opening[phoneId]?.key == key { opening[phoneId] = nil } }
        let transport = try await task.value
        cached[phoneId] = (key, transport)
        return transport
    }

    public func invalidate(phoneId: String) {
        cached[phoneId] = nil
    }

    // MARK: Merging

    private static func key(_ phone: RegisteredPhone) -> String {
        "\(phone.sourceId)\u{1}\(phone.phone.address)"
    }

    /// Lower is better: ready first, then ADB over USB, ADB over Wi-Fi, MTP (or MTP
    /// first when the user prefers it).
    static func rank(_ phone: DiscoveredPhone, preferMTP: Bool) -> Int {
        let ready = phone.state == .ready ? 0 : 100
        let wire = (phone.connection.wire == .mtp) != preferMTP ? 10 : 0
        let link = phone.connection.link == .usb ? 0 : 1
        return ready + wire + link
    }

    static func merge(_ found: [(sourceId: String, phone: DiscoveredPhone)], preferMTP: Bool) -> [RegisteredPhone] {
        var order: [String] = []
        var groups: [String: [(sourceId: String, phone: DiscoveredPhone)]] = [:]
        for item in found {
            if groups[item.phone.id] == nil { order.append(item.phone.id) }
            groups[item.phone.id, default: []].append(item)
        }
        return order.map { id in
            let members = groups[id]!.enumerated().sorted { lhs, rhs in
                let (l, r) = (rank(lhs.element.phone, preferMTP: preferMTP), rank(rhs.element.phone, preferMTP: preferMTP))
                return l == r ? lhs.offset < rhs.offset : l < r
            }.map(\.element)
            let best = members[0]
            var connections: [ConnectionKind] = []
            for member in members where !connections.contains(member.phone.connection) {
                connections.append(member.phone.connection)
            }
            // A conflict reported by any source wins: writing could hit the wrong phone.
            let phone = members.contains { $0.phone.state == .conflict }
                ? DiscoveredPhone(id: id, model: best.phone.model, connection: best.phone.connection,
                                  state: .conflict, address: best.phone.address)
                : best.phone
            return RegisteredPhone(phone: phone, sourceId: best.sourceId, connections: connections)
        }
    }
}
