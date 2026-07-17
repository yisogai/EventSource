//
//  RetryScheduler.swift
//  EventSource
//

import Foundation

/// Abstraction over reconnect-delay scheduling so tests can control time.
protocol RetryScheduler: Sendable {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void)
}

struct MainQueueRetryScheduler: RetryScheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
