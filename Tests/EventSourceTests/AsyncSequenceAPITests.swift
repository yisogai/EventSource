import Foundation
import Testing
@testable import EventSource

/// Collects a stream's elements in the background so tests can assert on what
/// has arrived so far and on whether the stream has finished.
final class StreamCollector<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _elements: [Element] = []
    private var _finished = false
    private var task: Task<Void, Never>?

    var elements: [Element] {
        lock.lock(); defer { lock.unlock() }
        return _elements
    }

    var finished: Bool {
        lock.lock(); defer { lock.unlock() }
        return _finished
    }

    init(_ stream: AsyncStream<Element>) {
        task = Task { [weak self] in
            for await element in stream {
                self?.record(element)
            }
            self?.markFinished()
        }
    }

    private func record(_ element: Element) {
        lock.lock(); defer { lock.unlock() }
        _elements.append(element)
    }

    private func markFinished() {
        lock.lock(); defer { lock.unlock() }
        _finished = true
    }

    func cancel() {
        task?.cancel()
    }
}

// Defined as an extension so these tests join the `.serialized` suite that
// owns the process-global MockSSEProtocol state.
extension ConnectionCharacterizationTests {
    @Test func asyncEvents_receivesEventsInOrder() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse())
        let (source, _, _) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { source.readyState == .open })
        let collector = StreamCollector(source.events)
        MockSSEProtocol.sendToActive("data: 1\n\ndata: 2\n\ndata: 3\n\n")

        #expect(await waitUntil { collector.elements.count == 3 })
        #expect(collector.elements.map(\.data) == ["1", "2", "3"])
    }

    @Test func asyncEvents_multicast_everySubscriberReceivesAll() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse())
        let (source, _, _) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { source.readyState == .open })
        let first = StreamCollector(source.events)
        let second = StreamCollector(source.events)
        MockSSEProtocol.sendToActive("event: tick\ndata: x\n\n")

        #expect(await waitUntil { first.elements.count == 1 && second.elements.count == 1 })
        #expect(first.elements == [MessageEvent(lastEventId: nil, type: "tick", data: "x")])
        #expect(first.elements == second.elements)
    }

    @Test func asyncEvents_finishOnClose_afterDeliveringPendingEvents() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["data: x\n\n"]))
        let (source, _, _) = makeSource()

        let collector = StreamCollector(source.events)
        #expect(await waitUntil { collector.elements.count == 1 })
        source.close()
        #expect(await waitUntil { collector.finished })
    }

    @Test func asyncEvents_survivesAutomaticReconnect() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["data: before\n\n"]))
        let (source, _, scheduler) = makeSource()
        defer { source.close() }

        let collector = StreamCollector(source.events)
        #expect(await waitUntil { collector.elements.count == 1 })

        MockSSEProtocol.failActive(.networkConnectionLost)
        #expect(await waitUntil { scheduler.pendingCount == 1 })
        MockSSEProtocol.enqueue(.sse(chunks: ["data: after\n\n"]))
        scheduler.fireNext()

        #expect(await waitUntil { collector.elements.count == 2 })
        #expect(collector.elements.map(\.data) == ["before", "after"])
        #expect(!collector.finished)
    }

    @Test func asyncEvents_cancellingSubscriber_keepsConnectionOpen() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse())
        let (source, recorder, _) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { source.readyState == .open })
        let collector = StreamCollector(source.events)
        collector.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)

        MockSSEProtocol.sendToActive("data: still-alive\n\n")
        #expect(await waitUntil { recorder.events.count == 1 })
        #expect(source.readyState == .open)
        #expect(collector.elements.isEmpty)
    }

    @Test func asyncStateChanges_yieldsClosedOnClose_thenFinishes() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse())
        let (source, _, _) = makeSource()

        #expect(await waitUntil { source.readyState == .open })
        let collector = StreamCollector(source.stateChanges)
        source.close()

        #expect(await waitUntil { collector.finished })
        #expect(collector.elements.last == .closed)
    }

    @Test func asyncEvents_finishWhenSourceIsDeallocated() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["data: x\n\n"]))
        var source: EventSource?
        do {
            let made = makeSource()
            source = made.0
        }
        let collector = StreamCollector(source!.events)
        #expect(await waitUntil { collector.elements.count == 1 })

        source = nil
        #expect(await waitUntil { collector.finished })
    }
}
