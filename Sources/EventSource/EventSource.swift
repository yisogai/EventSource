//
//  EventSource.swift
//  EventSource
//
//  Created by yisogai on 2017/11/01.
//  Copyright © 2017年 yisogai. All rights reserved.
//

import Foundation

/// Creates the `URLSession` used for a connection attempt. Injectable so tests
/// can substitute `URLProtocol`-backed configurations or a custom session.
public typealias URLSessionProvider = @Sendable (
    _ configuration: URLSessionConfiguration,
    _ delegate: URLSessionDelegate,
    _ delegateQueue: OperationQueue
) -> URLSession

open class EventSource: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public let url: URL

    public let headers: [String: String]

    public var lastEventId: String? { lock.withLock { _lastEventId } }
    public var retryTime: TimeInterval { lock.withLock { _retryTime } }
    public var readyState: ReadyState { lock.withLock { _readyState } }

    // All mutable state below is guarded by `lock`. User-facing handlers are
    // read out under the lock and invoked on the main queue, never while the
    // lock is held.
    private let lock = Lock()
    private var _lastEventId: String?
    private var _retryTime: TimeInterval
    private var _readyState: ReadyState = .closed
    private var _connectionStateOpened = false
    private var _session: URLSession?
    private var _responseFailure: ResponseFailure?

    private enum ResponseFailure {
        case retryable(EventSourceError)
        case fatal(EventSourceError)
    }
    private var _retryScheduler: RetryScheduler = MainQueueRetryScheduler()

    private var _onReadyStateChangedHandler: ((ReadyState) -> Void)?
    private var _onOpenHandler: (() -> Void)?
    private var _onErrorHandler: ((Error?) -> Void)?
    private var _onMessageHandler: ((MessageEvent) -> Void)?
    private var _eventListeners: [String: ((MessageEvent) -> Void)] = [:]
    private var _eventContinuations: [UUID: AsyncStream<MessageEvent>.Continuation] = [:]
    private var _stateContinuations: [UUID: AsyncStream<ReadyState>.Continuation] = [:]

    // Serial so delegate callbacks arrive in order and never overlap.
    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let eventBuffer = EventBuffer()
    private let sessionProvider: URLSessionProvider
    private let delegateProxy = SessionDelegateProxy()

    var retryScheduler: RetryScheduler {
        get { lock.withLock { _retryScheduler } }
        set { lock.withLock { _retryScheduler = newValue } }
    }

    public init(url: URL, configuration: Configuration? = nil, sessionProvider: URLSessionProvider? = nil) {
        self.url = url
        self.sessionProvider = sessionProvider ?? { URLSession(configuration: $0, delegate: $1, delegateQueue: $2) }

        let config = configuration ?? Configuration()
        self.headers = config.headers
        self._lastEventId = config.lastEventId
        self._retryTime = config.retryTime

        super.init()

        delegateProxy.target = self

        eventBuffer.retryTimeHandler = { [weak self] time in
            guard let this = self else { return }
            this.lock.withLock { this._retryTime = time }
        }
        eventBuffer.lastEventIdHandler = { [weak self] id in
            guard let this = self else { return }
            this.lock.withLock { this._lastEventId = id }
        }
        eventBuffer.eventHandler = { [weak self] event in
            self?.dispatchEvent(event)
        }

        connect()
    }

    deinit {
        // close() must not be used here: it dispatches notifications that
        // weakly capture self, and forming a weak reference to an instance
        // that is already deinitializing traps at runtime.
        let session: URLSession? = lock.withLock {
            let session = _session
            _session = nil
            _connectionStateOpened = false
            _readyState = .closed
            return session
        }
        session?.invalidateAndCancel()
        finishAllStreams()
    }

    // MARK: - Connection
    open func connect() {
        teardownConnection()

        var headers = self.headers
        headers["Accept"] = "text/event-stream"
        headers["Cache-Control"] = "no-cache"
        // WHATWG: the header is only sent when the last event ID is non-empty.
        if let eventId = lastEventId, !eventId.isEmpty {
            headers["Last-Event-ID"] = eventId
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(Int32.max)
        config.timeoutIntervalForResource = TimeInterval(Int32.max)
        config.httpAdditionalHeaders = headers

        setReadyState(.connecting)
        let session = sessionProvider(config, delegateProxy, operationQueue)
        let stale: URLSession? = lock.withLock {
            let stale = _session
            _session = session
            _connectionStateOpened = true
            return stale
        }
        // Non-nil only when another connect() raced this one; drop its session.
        stale?.invalidateAndCancel()
        session.dataTask(with: url).resume()
    }

    open func close() {
        teardownConnection()
        finishAllStreams()
    }

    /// Tears down the current connection without finishing async streams.
    /// connect() uses this for reconnects so subscriptions survive them; only
    /// a user-facing close() (or deinit) ends the streams.
    private func teardownConnection() {
        let session: URLSession? = lock.withLock {
            let session = _session
            _session = nil
            _connectionStateOpened = false
            _responseFailure = nil
            return session
        }
        setReadyState(.closed)
        session?.invalidateAndCancel()
        eventBuffer.reset(lastEventId: lastEventId)
    }

    private func finishAllStreams() {
        // Snapshot under the lock, finish outside it: finish() can invoke
        // onTermination synchronously, which re-enters the (non-recursive)
        // lock to unregister.
        let (events, states) = lock.withLock {
            let snapshot = (Array(_eventContinuations.values), Array(_stateContinuations.values))
            _eventContinuations.removeAll()
            _stateContinuations.removeAll()
            return snapshot
        }
        events.forEach { $0.finish() }
        states.forEach { $0.finish() }
    }

    // MARK: - Handlers
    open func onReadyStateChanged(_ handler: ((ReadyState) -> Void)?) {
        lock.withLock { _onReadyStateChangedHandler = handler }
    }

    open func onOpen(_ handler: (() -> Void)?) {
        lock.withLock { _onOpenHandler = handler }
    }

    open func onError(_ handler: ((Error?) -> Void)?) {
        lock.withLock { _onErrorHandler = handler }
    }

    open func onMessage(_ handler: ((MessageEvent) -> Void)?) {
        lock.withLock { _onMessageHandler = handler }
    }

    open func addEventListener(_ eventType: String, _ handler: ((MessageEvent) -> Void)?) {
        if let handler = handler {
            lock.withLock { _eventListeners[eventType] = handler }
        } else {
            removeEventListener(eventType)
        }
    }

    open func removeEventListener(_ eventType: String) {
        lock.withLock { _ = _eventListeners.removeValue(forKey: eventType) }
    }

    // MARK: - URLSessionDataDelegate
    // Kept public for source compatibility; the session's actual delegate is
    // the internal weak proxy, which forwards to the handle* methods below.
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handleReceivedData(data, from: session)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        handleReceivedResponse(response, from: session, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        handleCompletion(error: error, from: session)
    }

    // MARK: - Connection event handling
    // Every entry point ignores callbacks from sessions that are no longer
    // current: after close() or a replacing connect(), the old session's
    // asynchronous cancellation must not disturb the new connection's state.
    private func isCurrent(_ session: URLSession) -> Bool {
        lock.withLock { _session === session }
    }

    func handleReceivedData(_ data: Data, from session: URLSession) {
        guard isCurrent(session), readyState == .open else { return }
        eventBuffer.append(data)
    }

    func handleReceivedResponse(_ response: URLResponse, from session: URLSession, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard isCurrent(session) else {
            completionHandler(.cancel)
            return
        }
        // WHATWG: only a 200 response with text/event-stream opens the stream.
        // 500/502/503/504 reconnect like network errors; anything else fails
        // the connection for good. Non-HTTP responses are accepted as-is.
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 200
        let contentType = http.flatMap { $0.value(forHTTPHeaderField: "Content-Type") }
        // MIME type only — parameters like "; charset=utf-8" are ignored.
        let mimeType = contentType?.lowercased()
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        let isEventStream = http == nil || mimeType == "text/event-stream"

        if statusCode == 200 && isEventStream {
            completionHandler(.allow)
            setReadyState(.open)
            DispatchQueue.main.async { [weak self] in
                guard let this = self else { return }
                let handler = this.lock.withLock { this._onOpenHandler }
                handler?()
            }
            return
        }

        let failure = EventSourceError.unacceptableResponse(statusCode: statusCode, contentType: contentType)
        let retryable = [500, 502, 503, 504].contains(statusCode)
        lock.withLock {
            _responseFailure = retryable ? .retryable(failure) : .fatal(failure)
            if !retryable {
                _connectionStateOpened = false
            }
        }
        completionHandler(.cancel)
    }

    func handleCompletion(error: Error?, from session: URLSession) {
        guard isCurrent(session) else { return }
        eventBuffer.finishStream()
        setReadyState(.closed)

        let responseFailure: ResponseFailure? = lock.withLock {
            let failure = _responseFailure
            _responseFailure = nil
            return failure
        }

        let reportedError: Error?
        let shouldReconnect: Bool
        switch responseFailure {
        case .retryable(let failure):
            reportedError = failure
            shouldReconnect = true
        case .fatal(let failure):
            reportedError = failure
            shouldReconnect = false
        case nil:
            reportedError = error
            if let error = error, (error as NSError).code == NSURLErrorCancelled {
                shouldReconnect = false
            } else {
                shouldReconnect = true
            }
        }

        if shouldReconnect {
            let (delay, scheduler) = lock.withLock { (_retryTime, _retryScheduler) }
            scheduler.schedule(after: delay) { [weak self] in
                guard let this = self, this.lock.withLock({ this._connectionStateOpened }) else { return }
                this.connect()
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let this = self else { return }
            let handler = this.lock.withLock { this._onErrorHandler }
            handler?(reportedError)
        }
    }

    // MARK: - Async stream plumbing (public API in EventSource+AsyncSequence)
    func makeEventStream(bufferingPolicy: AsyncStream<MessageEvent>.Continuation.BufferingPolicy) -> AsyncStream<MessageEvent> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                guard let this = self else { return }
                this.lock.withLock { _ = this._eventContinuations.removeValue(forKey: id) }
            }
            lock.withLock { _eventContinuations[id] = continuation }
        }
    }

    func makeStateStream(bufferingPolicy: AsyncStream<ReadyState>.Continuation.BufferingPolicy) -> AsyncStream<ReadyState> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                guard let this = self else { return }
                this.lock.withLock { _ = this._stateContinuations.removeValue(forKey: id) }
            }
            lock.withLock { _stateContinuations[id] = continuation }
        }
    }

    // MARK: - Private
    private func setReadyState(_ newValue: ReadyState) {
        let continuations: [AsyncStream<ReadyState>.Continuation] = lock.withLock {
            _readyState = newValue
            return Array(_stateContinuations.values)
        }
        continuations.forEach { $0.yield(newValue) }
        // Matches the original didSet behavior: the notified value is the
        // state at delivery time on the main queue, not at mutation time.
        DispatchQueue.main.async { [weak self] in
            guard let this = self else { return }
            let (state, handler) = this.lock.withLock { (this._readyState, this._onReadyStateChangedHandler) }
            handler?(state)
        }
    }

    private func dispatchEvent(_ event: MessageEvent) {
        let continuations = lock.withLock { Array(_eventContinuations.values) }
        continuations.forEach { $0.yield(event) }
        DispatchQueue.main.async { [weak self] in
            guard let this = self else { return }
            let (message, listener) = this.lock.withLock { (this._onMessageHandler, this._eventListeners[event.type]) }
            if event.type == "message" {
                message?(event)
            }
            listener?(event)
        }
    }
}
