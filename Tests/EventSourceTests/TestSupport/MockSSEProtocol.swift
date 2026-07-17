import Foundation

/// Script-driven `URLProtocol` for SSE connection tests.
///
/// Tests enqueue one `Script` per expected request (FIFO). Each script is
/// played back synchronously in `startLoading`. `.stayOpen` leaves the
/// connection alive until the session cancels it.
final class MockSSEProtocol: URLProtocol {
    enum Step {
        case respond(status: Int, headers: [String: String])
        case chunk(Data)
        case error(URLError.Code)
        case finish
        case stayOpen
    }

    struct Script {
        var steps: [Step]

        static func sse(status: Int = 200,
                        contentType: String = "text/event-stream",
                        chunks: [String] = [],
                        then final: Step = .stayOpen) -> Script {
            var steps: [Step] = [.respond(status: status, headers: ["Content-Type": contentType])]
            steps.append(contentsOf: chunks.map { .chunk(Data($0.utf8)) })
            steps.append(final)
            return Script(steps: steps)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scriptQueue: [Script] = []
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var liveInstances: [MockSSEProtocol] = []

    static func enqueue(_ script: Script) {
        lock.lock(); defer { lock.unlock() }
        scriptQueue.append(script)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        scriptQueue = []
        capturedRequests = []
        liveInstances = []
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests
    }

    /// Delivers additional bytes on the most recently started still-open
    /// connection, so tests can subscribe first and send events afterwards.
    static func sendToActive(_ text: String) {
        lock.lock()
        let instance = liveInstances.last
        lock.unlock()
        guard let instance else { return }
        instance.client?.urlProtocol(instance, didLoad: Data(text.utf8))
    }

    /// Fails the most recently started still-open connection. Lets tests keep
    /// a `.stayOpen` stream alive until a condition holds, then kill it.
    static func failActive(_ code: URLError.Code) {
        lock.lock()
        let instance = liveInstances.popLast()
        lock.unlock()
        guard let instance else { return }
        instance.client?.urlProtocol(instance, didFailWithError: URLError(code))
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        Self.liveInstances.append(self)
        let script = Self.scriptQueue.isEmpty ? nil : Self.scriptQueue.removeFirst()
        Self.lock.unlock()

        guard let script else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        for step in script.steps {
            switch step {
            case .respond(let status, let headers):
                let response = HTTPURLResponse(url: request.url!,
                                               statusCode: status,
                                               httpVersion: "HTTP/1.1",
                                               headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            case .chunk(let data):
                client?.urlProtocol(self, didLoad: data)
            case .error(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            case .finish:
                client?.urlProtocolDidFinishLoading(self)
                return
            case .stayOpen:
                return
            }
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.liveInstances.removeAll { $0 === self }
        Self.lock.unlock()
    }
}
