import DroidCore
import Foundation

/// Directory listings in progress on behalf of the extension. A listing is pulled batch
/// by batch (`listNext`) so Finder shows the first 500 entries of a 10,000-file folder
/// before the rest is read (spec §9), whatever the transport.
actor ListingSessions {
    static let idleTimeout: TimeInterval = 120

    private final class Session: @unchecked Sendable {
        // Guarded by the owning actor.
        var buffer: [[RemoteEntry]] = []
        var finished = false
        var failure: Error?
        var waiter: CheckedContinuation<Void, Never>?
        var producer: Task<Void, Never>?
        var lastAccess = Date()
    }

    private var sessions: [String: Session] = [:]

    func start(_ stream: AsyncThrowingStream<[RemoteEntry], Error>) -> String {
        sweep()
        let id = UUID().uuidString
        let session = Session()
        sessions[id] = session
        session.producer = Task { [weak self] in
            do {
                for try await batch in stream {
                    await self?.push(batch, to: id)
                }
                await self?.end(id, failure: nil)
            } catch {
                await self?.end(id, failure: error)
            }
        }
        return id
    }

    /// The next batch, or `done` with whatever is left. Throws the transport's error.
    func next(_ id: String) async throws -> (batch: [RemoteEntry], done: Bool) {
        guard let session = sessions[id] else {
            throw DeviceError.protocolError("Unknown or expired listing")
        }
        session.lastAccess = Date()
        while session.buffer.isEmpty && !session.finished {
            await withCheckedContinuation { session.waiter = $0 }
        }
        if !session.buffer.isEmpty {
            let batch = session.buffer.removeFirst()
            let done = session.finished && session.buffer.isEmpty && session.failure == nil
            if done { sessions[id] = nil }
            return (batch, done)
        }
        sessions[id] = nil
        if let failure = session.failure { throw failure }
        return ([], true)
    }

    func cancel(_ id: String) {
        sessions.removeValue(forKey: id)?.producer?.cancel()
    }

    var count: Int { sessions.count }

    private func push(_ batch: [RemoteEntry], to id: String) {
        guard let session = sessions[id] else { return }
        session.buffer.append(batch)
        wake(session)
    }

    private func end(_ id: String, failure: Error?) {
        guard let session = sessions[id] else { return }
        session.finished = true
        session.failure = failure
        wake(session)
    }

    private func wake(_ session: Session) {
        session.waiter?.resume()
        session.waiter = nil
    }

    /// Drops listings the extension abandoned (it was killed mid-listing).
    private func sweep(now: Date = Date()) {
        for (id, session) in sessions where now.timeIntervalSince(session.lastAccess) > Self.idleTimeout
            && session.waiter == nil {
            cancel(id)
        }
    }
}
