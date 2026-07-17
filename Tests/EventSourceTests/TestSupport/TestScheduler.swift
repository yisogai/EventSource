import Foundation
@testable import EventSource

/// `RetryScheduler` that captures scheduled work instead of waiting real time.
/// Tests inspect `delays` and invoke `fireNext()` to advance "time" manually.
final class TestScheduler: RetryScheduler, @unchecked Sendable {
    private struct Entry {
        let delay: TimeInterval
        let work: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    var delays: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.delay)
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(delay: delay, work: work))
    }

    /// Runs the oldest scheduled work. Returns false if nothing was pending.
    @discardableResult
    func fireNext() -> Bool {
        lock.lock()
        guard !entries.isEmpty else {
            lock.unlock()
            return false
        }
        let entry = entries.removeFirst()
        lock.unlock()
        entry.work()
        return true
    }
}
