import Foundation

/// FIFO mutex for async code. An actor alone does not serialize work that awaits inside
/// it (actors are re-entrant), but a USB bulk pipe must not interleave two packets'
/// transfers, and MTP allows one operation at a time (spec §5.2).
public actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            // Ownership passes straight to the next waiter; `locked` stays true.
            waiters.removeFirst().resume()
        }
    }

    public func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        do {
            let value = try await body()
            unlock()
            return value
        } catch {
            unlock()
            throw error
        }
    }
}
