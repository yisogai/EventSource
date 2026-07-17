import Foundation
import Testing
@testable import EventSource

/// Characterization tests: these pin down the CURRENT connection behavior as a
/// baseline before the spec-compliance work. Tests marked "will change" assert
/// behavior that intentionally changes when WHATWG response validation lands.
@Suite("Connection characterization (current behavior baseline)", .serialized)
struct ConnectionCharacterizationTests {
    private static let url = URL(string: "https://mock.example/stream")!

    /// Builds an EventSource wired to MockSSEProtocol and a TestScheduler.
    /// `EventSource.init` auto-connects, so scripts must be enqueued BEFORE
    /// calling this. The scheduler/recorder are attached immediately after
    /// init, ahead of any async delegate callback.
    func makeSource(
        configuration: Configuration? = nil,
        listeningTo eventTypes: [String] = []
    ) -> (EventSource, ConnectionRecorder, TestScheduler) {
        let source = EventSource(url: Self.url, configuration: configuration) { config, delegate, queue in
            config.protocolClasses = [MockSSEProtocol.self]
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        let scheduler = TestScheduler()
        source.retryScheduler = scheduler
        let recorder = ConnectionRecorder()
        recorder.attach(to: source, listeningTo: eventTypes)
        return (source, recorder, scheduler)
    }

    @Test func successfulConnection_opensAndDeliversMessages_onMainThread() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["data: hi\n\n"]))
        let (source, recorder, _) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { recorder.events.count == 1 })
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "message", data: "hi")])
        #expect(source.readyState == .open)
        #expect(recorder.eventsOnMain.allSatisfy { $0 })
        #expect(await waitUntil { recorder.openCount == 1 })
        #expect(recorder.openOnMain.allSatisfy { $0 })
    }

    @Test func namedEvent_goesToListener_notOnMessage() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["event: ping\ndata: x\n\n"]))
        let (source, recorder, _) = makeSource(listeningTo: ["ping"])
        defer { source.close() }

        #expect(await waitUntil { recorder.events.count == 1 })
        #expect(recorder.events == [MessageEvent(lastEventId: nil, type: "ping", data: "x")])
    }

    // BEHAVIOR CHANGE (h): per WHATWG, a 500 response no longer opens the
    // stream or parses its body; it is reported through onError and, like the
    // other 5xx codes the spec lists, schedules a reconnect. Previously any
    // response opened the stream and its body was parsed as SSE.
    @Test func spec_non200Response_wasOpened_nowFailsAndReconnects() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(status: 500, chunks: ["data: x\n\n"]))
        let (source, recorder, scheduler) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { recorder.errors.count == 1 })
        #expect(recorder.errors.first as? EventSourceError
            == .unacceptableResponse(statusCode: 500, contentType: "text/event-stream"))
        #expect(recorder.events.isEmpty)
        #expect(recorder.openCount == 0)
        #expect(source.readyState == .closed)
        #expect(await waitUntil { scheduler.pendingCount == 1 })
    }

    // BEHAVIOR CHANGE (h): per WHATWG, a 200 response whose Content-Type is
    // not text/event-stream fails the connection for good — no open, no
    // parsing, no reconnect. Previously the body was parsed as SSE (delivered
    // at EOF because URLSession buffers non-streaming content types).
    @Test func spec_wrongContentType_wasParsed_nowFatalFailure() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(contentType: "text/plain", chunks: ["data: x\n\n"], then: .finish))
        let (source, recorder, scheduler) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { recorder.errors.count == 1 })
        #expect(recorder.errors.first as? EventSourceError
            == .unacceptableResponse(statusCode: 200, contentType: "text/plain"))
        #expect(recorder.events.isEmpty)
        #expect(recorder.openCount == 0)
        #expect(source.readyState == .closed)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func networkError_schedulesReconnectAfterRetryTime_andReportsError() async {
        MockSSEProtocol.reset()
        // Pre-response failure: the reliable error-delivery path on iOS
        // runtimes (a post-response injected error is sometimes dropped).
        MockSSEProtocol.enqueue(MockSSEProtocol.Script(steps: [.error(.timedOut)]))
        let (source, recorder, scheduler) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { scheduler.pendingCount == 1 })
        #expect(scheduler.delays == [3.0])
        #expect(await waitUntil { recorder.errors.count == 1 })
        #expect(recorder.errors.first??._code == URLError.timedOut.rawValue)

        MockSSEProtocol.enqueue(.sse())
        scheduler.fireNext()
        #expect(await waitUntil { MockSSEProtocol.requests.count == 2 })
    }

    @Test func reconnect_sendsLastEventIdHeader() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["id: 55\ndata: x\n\n"]))
        let (source, recorder, scheduler) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { recorder.events.count == 1 })
        #expect(source.lastEventId == "55")
        #expect(MockSSEProtocol.requests.first?.value(forHTTPHeaderField: "Last-Event-ID") == nil)

        MockSSEProtocol.finishActive()
        #expect(await waitUntil { scheduler.pendingCount == 1 })

        MockSSEProtocol.enqueue(.sse())
        scheduler.fireNext()
        #expect(await waitUntil { MockSSEProtocol.requests.count == 2 })
        #expect(MockSSEProtocol.requests.last?.value(forHTTPHeaderField: "Last-Event-ID") == "55")
    }

    @Test func retryDirective_changesScheduledReconnectDelay() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["retry: 100\n\n"]))
        let (source, _, scheduler) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { source.retryTime == 0.1 })
        MockSSEProtocol.finishActive()
        #expect(await waitUntil { scheduler.pendingCount == 1 })
        #expect(scheduler.delays == [0.1])
    }

    @Test func close_preventsScheduledReconnect() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(MockSSEProtocol.Script(steps: [.error(.timedOut)]))
        let (source, _, scheduler) = makeSource()

        #expect(await waitUntil { scheduler.pendingCount == 1 })
        source.close()
        scheduler.fireNext()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(MockSSEProtocol.requests.count == 1)
        #expect(source.readyState == .closed)
    }

    // Added with the weak-delegate-proxy fix: dropping the last reference now
    // deallocates the EventSource (and tears down its connection). Previously
    // URLSession's strong delegate reference leaked the instance until close().
    @Test func droppingLastReference_deallocatesEventSource() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["data: x\n\n"]))
        var source: EventSource?
        let recorder: ConnectionRecorder
        do {
            let made = makeSource()
            source = made.0
            recorder = made.1
        }
        let box = WeakBox(source)

        #expect(await waitUntil { recorder.events.count == 1 })
        source = nil
        #expect(await waitUntil { box.value == nil })
    }

    // BEHAVIOR CHANGE (k): callbacks from a session that is no longer current
    // are ignored, so close() no longer surfaces its own cancellation as a
    // spurious NSURLErrorCancelled through onError. (Previously close() was
    // followed by an onError(-999) call.)
    @Test func spec_close_wasCancelledErrorReported_nowSilent() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["data: x\n\n"]))
        let (source, recorder, scheduler) = makeSource()

        #expect(await waitUntil { recorder.events.count == 1 })
        source.close()
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(recorder.errors.isEmpty)
        #expect(scheduler.pendingCount == 0)
        #expect(source.readyState == .closed)
    }

    // Regression test for the stale-session bug: calling connect() on a live
    // EventSource must not let the old session's asynchronous cancellation
    // close the replacement connection or leak a spurious error.
    @Test func manualConnect_whileOpen_replacementConnectionSurvives() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["data: first\n\n"]))
        let (source, recorder, _) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { recorder.events.count == 1 })

        MockSSEProtocol.enqueue(.sse())
        source.connect()
        #expect(await waitUntil { MockSSEProtocol.requests.count == 2 })
        #expect(await waitUntil { source.readyState == .open })
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(source.readyState == .open)
        #expect(recorder.errors.isEmpty)

        MockSSEProtocol.sendToActive("data: second\n\n")
        #expect(await waitUntil { recorder.events.count == 2 })
        #expect(recorder.events.last?.data == "second")
    }

    // BEHAVIOR CHANGE (f): an empty last event ID means the Last-Event-ID
    // header is omitted on reconnect, per spec.
    @Test func reconnect_afterEmptyId_omitsLastEventIdHeader() async {
        MockSSEProtocol.reset()
        MockSSEProtocol.enqueue(.sse(chunks: ["id: 5\ndata: a\n\nid:\ndata: b\n\n"]))
        let (source, recorder, scheduler) = makeSource()
        defer { source.close() }

        #expect(await waitUntil { recorder.events.count == 2 })
        #expect(source.lastEventId == "")

        MockSSEProtocol.finishActive()
        #expect(await waitUntil { scheduler.pendingCount == 1 })
        MockSSEProtocol.enqueue(.sse())
        scheduler.fireNext()
        #expect(await waitUntil { MockSSEProtocol.requests.count == 2 })
        #expect(MockSSEProtocol.requests.last?.value(forHTTPHeaderField: "Last-Event-ID") == nil)
    }
}
