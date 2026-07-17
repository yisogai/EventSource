import Foundation

/// Holds a weak reference in a form that `@Sendable` closures can capture.
final class WeakBox<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: T?

    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    init(_ value: T?) {
        _value = value
    }
}

/// Polls `condition` (roughly every 10 ms) until it returns true or `timeout`
/// elapses. Returns the final value of `condition`.
func waitUntil(timeout: TimeInterval = 5.0, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
