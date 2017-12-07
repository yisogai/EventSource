//
//  EventSource.swift
//  EventSource
//
//  Created by yisogai on 2017/11/01.
//  Copyright © 2017年 yisogai. All rights reserved.
//

import Foundation

open class EventSource: NSObject, URLSessionDataDelegate {
    public let url: URL
    
    public let headers: [String: String]
    public private(set) var lastEventId: String?
    public private(set) var retryTime: TimeInterval
    
    public private(set) var readyState: ReadyState = .closed {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let this = self else { return }
                this.onReadyStateChangedHandler?(this.readyState)
            }
        }
    }
    
    private var onReadyStateChangedHandler: ((ReadyState) -> Void)?
    private var onOpenHandler: (() -> Void)?
    private var onErrorHandler: ((Error?) -> Void)?
    private var onMessageHandler: ((MessageEvent) -> Void)?
    private var eventListeners: [String: ((MessageEvent) -> Void)] = [:]
    
    private var session: URLSession?
    private var operationQueue = OperationQueue()
    
    private let eventBuffer = EventBuffer()
    
    private var connectionStateOpened = false
    
    public init(url: URL, configuration: Configuration? = nil) {
        self.url = url
        
        let config = configuration ?? Configuration()
        self.headers = config.headers
        self.lastEventId = config.lastEventId
        self.retryTime = config.retryTime
        
        super.init()
        
        eventBuffer.retryTimeHandler = { [weak self] time in self?.retryTime = time }
        eventBuffer.lastEventIdHandler = { [weak self] id in self?.lastEventId = id }
        eventBuffer.eventHandler = { event in
            DispatchQueue.main.async { [weak self] in
                guard let this = self else { return }
                if event.type == "message" {
                    this.onMessageHandler?(event)
                }
                this.eventListeners[event.type]?(event)
            }
        }
        
        connect()
    }
    
    deinit {
        close()
    }
    
    // MARK: - Connection
    open func connect() {
        close()
        
        var headers = self.headers
        headers["Accept"] = "text/event-stream"
        headers["Cache-Control"] = "no-cache"
        if let eventId = lastEventId {
            headers["Last-Event-ID"] = eventId
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(Int32.max)
        config.timeoutIntervalForResource = TimeInterval(Int32.max)
        config.httpAdditionalHeaders = headers
        
        readyState = .connecting
        connectionStateOpened = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: operationQueue)
        session?.dataTask(with: url).resume()
    }
    
    open func close() {
        readyState = .closed
        connectionStateOpened = false
        session?.invalidateAndCancel()
        session = nil
        eventBuffer.clearBuffer()
    }
    
    // MARK: - Handlers
    open func onReadyStateChanged(_ handler: ((ReadyState) -> Void)?) {
        onReadyStateChangedHandler = handler
    }
    
    open func onOpen(_ handler: (() -> Void)?) {
        onOpenHandler = handler
    }
    
    open func onError(_ handler: ((Error?) -> Void)?) {
        onErrorHandler = handler
    }
    
    open func onMessage(_ handler: ((MessageEvent) -> Void)?) {
        onMessageHandler = handler
    }
    
    open func addEventListener(_ eventType: String, _ handler: ((MessageEvent) -> Void)?) {
        if let handler = handler {
            eventListeners[eventType] = handler
        } else {
            removeEventListener(eventType)
        }
    }
    
    open func removeEventListener(_ eventType: String) {
        eventListeners.removeValue(forKey: eventType)
    }
    
    // MARK: - URLSessionDataDelegate
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard readyState == .open else { return }
        eventBuffer.append(data)
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
        
        readyState = .open
        DispatchQueue.main.async { [weak self] in
            self?.onOpenHandler?()
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        readyState = .closed
        
        if let error = error, (error as NSError).code == NSURLErrorCancelled {
            // cancelled
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(retryTime)) { [weak self] in
                guard let this = self, this.connectionStateOpened == true else { return }
                this.connect()
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.onErrorHandler?(error)
        }
    }
}
