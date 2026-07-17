//
//  EventSource+AsyncSequence.swift
//  EventSource
//

import Foundation

extension EventSource {
    /// All server-sent events, regardless of their `type` (filter on
    /// `MessageEvent.type` as needed).
    ///
    /// Each access creates a new, independent subscription: multiple
    /// concurrent `for await` loops each receive every event. The stream is
    /// transparent to automatic reconnects and finishes only on `close()` or
    /// when the EventSource is deallocated. Cancelling the consuming task
    /// ends that subscription only — it does NOT close the connection.
    ///
    /// Buffering is `.unbounded` by default so no event is dropped; a
    /// subscriber that stops consuming while the connection keeps delivering
    /// will accumulate memory. Use `events(bufferingPolicy:)` to bound it.
    public var events: AsyncStream<MessageEvent> {
        events()
    }

    /// See `events`; lets the subscriber choose the buffering policy, e.g.
    /// `.bufferingNewest(64)`.
    public func events(
        bufferingPolicy: AsyncStream<MessageEvent>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<MessageEvent> {
        makeEventStream(bufferingPolicy: bufferingPolicy)
    }

    /// `readyState` transitions as an async sequence. Same subscription
    /// semantics as `events`.
    public var stateChanges: AsyncStream<ReadyState> {
        stateChanges()
    }

    /// See `stateChanges`; lets the subscriber choose the buffering policy.
    public func stateChanges(
        bufferingPolicy: AsyncStream<ReadyState>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<ReadyState> {
        makeStateStream(bufferingPolicy: bufferingPolicy)
    }
}
