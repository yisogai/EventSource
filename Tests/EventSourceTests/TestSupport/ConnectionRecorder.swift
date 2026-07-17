import Foundation
@testable import EventSource

/// Records every callback an `EventSource` makes, together with whether it was
/// delivered on the main thread.
final class ConnectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _openCount = 0
    private var _openOnMain: [Bool] = []
    private var _events: [MessageEvent] = []
    private var _eventsOnMain: [Bool] = []
    private var _errors: [Error?] = []
    private var _states: [ReadyState] = []

    var openCount: Int { withLock { _openCount } }
    var openOnMain: [Bool] { withLock { _openOnMain } }
    var events: [MessageEvent] { withLock { _events } }
    var eventsOnMain: [Bool] { withLock { _eventsOnMain } }
    var errors: [Error?] { withLock { _errors } }
    var states: [ReadyState] { withLock { _states } }

    func attach(to source: EventSource, listeningTo eventTypes: [String] = []) {
        source.onOpen { [weak self] in
            self?.withLock {
                self?._openCount += 1
                self?._openOnMain.append(Thread.isMainThread)
            }
        }
        source.onMessage { [weak self] event in
            self?.record(event)
        }
        source.onError { [weak self] error in
            self?.withLock { self?._errors.append(error) }
        }
        source.onReadyStateChanged { [weak self] state in
            self?.withLock { self?._states.append(state) }
        }
        for type in eventTypes {
            source.addEventListener(type) { [weak self] event in
                self?.record(event)
            }
        }
    }

    private func record(_ event: MessageEvent) {
        withLock {
            _events.append(event)
            _eventsOnMain.append(Thread.isMainThread)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
