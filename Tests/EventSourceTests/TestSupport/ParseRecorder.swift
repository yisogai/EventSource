import Foundation
@testable import EventSource

/// Wraps an `EventBuffer` and records everything its handlers emit, in call order.
///
/// `EventBuffer` invokes its handlers synchronously from within `append(_:)`, so no
/// async waiting is needed: after `feed` returns, every handler call it triggered has
/// already been recorded.
final class ParseRecorder {
    private let buffer = EventBuffer()

    /// Every `MessageEvent` delivered via `eventHandler`, in delivery order.
    private(set) var events: [MessageEvent] = []

    /// Every value passed to `lastEventIdHandler`, in call order (including `nil`).
    private(set) var lastEventIdUpdates: [String?] = []

    /// Every value passed to `retryTimeHandler`, in call order.
    private(set) var retryTimeUpdates: [TimeInterval] = []

    init() {
        buffer.eventHandler = { [weak self] event in
            self?.events.append(event)
        }
        buffer.lastEventIdHandler = { [weak self] lastEventId in
            self?.lastEventIdUpdates.append(lastEventId)
        }
        buffer.retryTimeHandler = { [weak self] retryTime in
            self?.retryTimeUpdates.append(retryTime)
        }
    }

    /// Feeds raw bytes to the underlying `EventBuffer`. Handlers fire synchronously
    /// before this call returns.
    func feed(_ data: Data) {
        buffer.append(data)
    }

    /// Feeds a UTF-8 encoded string to the underlying `EventBuffer`. Handlers fire
    /// synchronously before this call returns.
    func feed(_ text: String) {
        feed(Data(text.utf8))
    }

    func clearBuffer() {
        buffer.reset(lastEventId: nil)
    }

    /// Signals end-of-stream, flushing a held-back trailing CR (see
    /// `EventBuffer.finishStream`).
    func finishStream() {
        buffer.finishStream()
    }
}
