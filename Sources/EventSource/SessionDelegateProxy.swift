//
//  SessionDelegateProxy.swift
//  EventSource
//

import Foundation

/// URLSession retains its delegate until the session is invalidated. Passing
/// this weak proxy as the delegate keeps that retain away from EventSource, so
/// dropping the last reference to an EventSource deinits it (which closes the
/// session) instead of leaking a live connection.
final class SessionDelegateProxy: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var target: EventSource?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        target?.handleReceivedData(data, from: session)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let target = target else {
            completionHandler(.cancel)
            return
        }
        target.handleReceivedResponse(response, from: session, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        target?.handleCompletion(error: error, from: session)
    }
}
