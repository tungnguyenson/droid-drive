import DroidCore
import Foundation
import Network

/// A bidirectional byte stream to one ADB service (`sync:`, `shell,v2:…`).
/// Provided either by an `AdbConnection` stream (packets multiplexed over USB/TCP) or by
/// a socket to the user's adb server after `host:transport:<serial>`.
public protocol AdbByteStream: Sendable {
    func write(_ data: Data) async throws
    /// Next chunk, or nil at end of stream.
    func read() async throws -> Data?
    func close() async
}

/// Anything that can open services on one device.
public protocol AdbServiceOpener: Sendable {
    /// Device features from the CNXN banner or `host-serial:<s>:features`.
    var features: Set<String> { get }
    func open(_ service: String) async throws -> any AdbByteStream
}

/// Buffers an `AdbByteStream` so codecs can ask for exact byte counts.
/// Owned by one task; not shared. Consumes the buffer by moving an offset instead of
/// copying the remainder, which made pulls O(n²) per received chunk.
final class StreamReader {
    private let stream: any AdbByteStream
    private var buffer = Data()
    private var offset = 0

    init(_ stream: any AdbByteStream) { self.stream = stream }

    private var available: Int { buffer.count - offset }

    /// Reads one more chunk into the buffer, dropping bytes already consumed.
    private func fill() async throws {
        guard let chunk = try await stream.read() else {
            throw DeviceError.protocolError("The device closed the stream early")
        }
        if offset == buffer.count {
            buffer = chunk
        } else {
            buffer = buffer.subdata(in: (buffer.startIndex + offset)..<buffer.endIndex) + chunk
        }
        offset = 0
    }

    private func take(_ count: Int) -> Data {
        let start = buffer.startIndex + offset
        offset += count
        return buffer.subdata(in: start..<(start + count))
    }

    func readExactly(_ count: Int) async throws -> [UInt8] {
        while available < count { try await fill() }
        return [UInt8](take(count))
    }

    /// Streams `count` bytes to `sink` without holding them all in memory.
    func forward(_ count: Int, to sink: (Data) throws -> Void) async throws {
        var left = count
        while left > 0 {
            if available == 0 { try await fill() }
            let n = min(left, available)
            try sink(take(n))
            left -= n
        }
    }

    /// Bytes already read from the stream but not yet consumed. A caller that hands the
    /// stream on must pass these along, or the start of the next reader's data is lost.
    func takeBuffered() -> Data { take(available) }

    func readToEnd() async throws -> Data {
        var out = take(available)
        while let chunk = try await stream.read() { out.append(chunk) }
        return out
    }
}

/// Replays bytes a `StreamReader` buffered before handing the stream on.
struct PrefixedStream: AdbByteStream {
    private let base: any AdbByteStream
    private let prefix: PrefixBox

    init(_ base: any AdbByteStream, prefix: Data) {
        self.base = base
        self.prefix = PrefixBox(prefix)
    }

    func write(_ data: Data) async throws { try await base.write(data) }

    func read() async throws -> Data? {
        if let first = prefix.take() { return first }
        return try await base.read()
    }

    func close() async { await base.close() }

    private final class PrefixBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        init(_ data: Data) { self.data = data.isEmpty ? nil : data }
        func take() -> Data? { lock.withLock { defer { data = nil }; return data } }
    }
}

/// A TCP connection (adbd over Wi-Fi/emulator, or the local adb server).
public final class TcpStream: AdbByteStream, @unchecked Sendable {
    // NWConnection is internally synchronized; `@unchecked` covers its missing annotation.
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "droiddrive.tcp")

    private init(connection: NWConnection) { self.connection = connection }

    public static func connect(host: String, port: UInt16, timeout: TimeInterval = 5) async throws -> TcpStream {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: NWParameters(tls: nil, tcp: tcp))
        let stream = TcpStream(connection: connection)
        try await stream.start()
        return stream
    }

    private func start() async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed, .cancelled:
                    once.run { continuation.resume(throwing: DeviceError.disconnected) }
                case .waiting:
                    // Refused or unreachable: NWConnection would retry forever.
                    once.run {
                        connection.cancel()
                        continuation.resume(throwing: DeviceError.disconnected)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    continuation.resume(throwing: DeviceError.disconnected)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else if error != nil {
                    continuation.resume(throwing: DeviceError.disconnected)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func close() async { connection.cancel() }
}

/// Runs a closure at most once across threads (NWConnection callbacks fire repeatedly).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// Counting semaphore for async code: caps concurrent transfers per device (spec §5.2).
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ count: Int) { available = count }

    public func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    public func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await wait()
        defer { signal() }
        return try await body()
    }
}
