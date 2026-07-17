import Foundation
import Testing
@testable import EventSource

/// Stateless URLProtocol (no shared script queue) so this suite can run in
/// parallel with the MockSSEProtocol-based suites.
private final class AlwaysOpenProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("id: 7\ndata: s\n\n".utf8))
    }

    override func stopLoading() {}
}

@Suite("Thread safety stress")
struct ThreadSafetyStressTests {
    @Test func concurrentPublicAPICalls_doNotCrashOrRace() async {
        let source = EventSource(url: URL(string: "https://stress.example/stream")!) { config, delegate, queue in
            config.protocolClasses = [AlwaysOpenProtocol.self]
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        source.retryScheduler = TestScheduler()
        defer { source.close() }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    for j in 0..<25 {
                        switch (i + j) % 6 {
                        case 0: source.connect()
                        case 1: _ = source.lastEventId
                        case 2: _ = source.readyState
                        case 3: _ = source.retryTime
                        case 4: source.addEventListener("t\(j)") { _ in }
                        default: source.removeEventListener("t\(j)")
                        }
                    }
                }
            }
        }

        source.close()
        #expect(source.readyState == .closed)
    }
}
