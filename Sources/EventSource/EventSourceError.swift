//
//  EventSourceError.swift
//  EventSource
//

import Foundation

public enum EventSourceError: Error, Equatable, Sendable {
    /// The server's response was not `200 OK` with `text/event-stream`, so
    /// the connection was not opened. Reported through `onError`.
    case unacceptableResponse(statusCode: Int, contentType: String?)
}
