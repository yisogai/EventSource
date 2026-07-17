//
//  Lock.swift
//  EventSource
//

import os

/// Minimal unfair-lock wrapper. `os_unfair_lock` must live at a stable memory
/// address, hence the manual allocation. Usable back to iOS 15 / macOS 12
/// (unlike `OSAllocatedUnfairLock` / `Synchronization.Mutex`).
final class Lock: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}
