//
//  EventBuffer.swift
//  EventSource
//
//  Created by yisogai on 2017/11/01.
//  Copyright © 2017年 yisogai. All rights reserved.
//

import Foundation

/// Incremental parser for a `text/event-stream` byte stream, following the
/// WHATWG HTML Standard's "Server-sent events" event stream interpretation:
/// lines are terminated by CR, LF, or CRLF; a blank line dispatches the
/// pending event; a leading UTF-8 BOM is stripped once per stream.
///
/// @unchecked Sendable: all mutable state is guarded by `lock`. The handler
/// properties are assigned once during EventSource.init before any concurrent
/// use.
internal final class EventBuffer: @unchecked Sendable {
    var retryTimeHandler: ((TimeInterval) -> Void)?
    var lastEventIdHandler: ((String?) -> Void)?
    var eventHandler: ((MessageEvent) -> Void)?

    private let lock = Lock()

    // Undecoded bytes: at most one incomplete trailing line.
    private var buffer = Data()
    // True once the stream head has been checked for (and stripped of) a BOM.
    private var checkedBOM = false

    // Per-stream buffers from the specification.
    private var dataBuffer = ""
    private var eventTypeBuffer = ""
    // Seeded with the connection's known last event ID (as Chromium does) so
    // an id-less event keeps reporting the previous ID instead of resetting.
    private var lastEventIdBuffer: String?
    // Last value reported through lastEventIdHandler, to avoid redundant calls.
    private var reportedLastEventId: String?

    func append(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            stripBOMIfNeeded()
            for line in extractCompleteLines() {
                processLine(line)
            }
        }
    }

    /// Handles end-of-stream: a held-back trailing CR (kept in case a LF
    /// followed) is now a definite line terminator, so process it. Any other
    /// incomplete trailing line is discarded, as the spec requires at EOF.
    func finishStream() {
        lock.withLock {
            guard buffer.last == 0x0D else { return }
            buffer.removeLast()
            processLine(buffer)
            buffer = Data()
        }
    }

    /// Resets all per-stream parser state for a new connection. `lastEventId`
    /// seeds the ID buffer with the value already known to the EventSource.
    func reset(lastEventId: String?) {
        lock.withLock {
            buffer = Data()
            checkedBOM = false
            dataBuffer = ""
            eventTypeBuffer = ""
            lastEventIdBuffer = lastEventId
            reportedLastEventId = lastEventId
        }
    }

    // MARK: - Byte layer (all called with `lock` held)

    private func stripBOMIfNeeded() {
        guard !checkedBOM else { return }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if buffer.count >= 3 {
            if buffer.prefix(3).elementsEqual(bom) {
                buffer.removeFirst(3)
            }
            checkedBOM = true
        } else if !buffer.elementsEqual(bom.prefix(buffer.count)) {
            // Too short to decide only while it is still a BOM prefix.
            checkedBOM = true
        }
    }

    /// Splits off every complete line (terminated by CR, LF, or CRLF),
    /// leaving an incomplete trailing line in `buffer`. A CR as the very last
    /// byte is kept back: the next chunk may complete it to CRLF.
    private func extractCompleteLines() -> [Data] {
        guard checkedBOM else { return [] }
        var lines: [Data] = []
        var lineStart = buffer.startIndex
        var index = buffer.startIndex
        let end = buffer.endIndex

        while index < end {
            switch buffer[index] {
            case 0x0A: // LF
                lines.append(buffer.subdata(in: lineStart..<index))
                index += 1
                lineStart = index
            case 0x0D: // CR or CRLF
                let next = index + 1
                if next == end {
                    // Trailing CR: wait for the next chunk.
                    index = end
                    break
                }
                lines.append(buffer.subdata(in: lineStart..<index))
                index = buffer[next] == 0x0A ? next + 1 : next
                lineStart = index
            default:
                index += 1
            }
        }

        buffer.removeSubrange(buffer.startIndex..<lineStart)
        return lines
    }

    // MARK: - Line layer

    private func processLine(_ line: Data) {
        if line.isEmpty {
            dispatchPendingEvent()
            return
        }
        if line.first == 0x3A { // ':' — comment line
            return
        }

        // The colon split and the removal of exactly one leading U+0020 SPACE
        // happen at the byte level, mirroring the spec's code-point rules
        // (grapheme-level string APIs would merge a combining character into
        // the preceding ':' or space and misparse the line). Invalid UTF-8
        // becomes U+FFFD instead of silently dropping the line.
        let name: String
        let value: String
        if let colonIndex = line.firstIndex(of: 0x3A) {
            name = String(decoding: line[line.startIndex..<colonIndex], as: UTF8.self)
            var valueBytes = line[line.index(after: colonIndex)...]
            if valueBytes.first == 0x20 {
                valueBytes = valueBytes.dropFirst()
            }
            value = String(decoding: valueBytes, as: UTF8.self)
        } else {
            name = String(decoding: line, as: UTF8.self)
            value = ""
        }
        processField(name: name, value: value)
    }

    private func processField(name: String, value: String) {
        switch name {
        case "event":
            eventTypeBuffer = value
        case "data":
            dataBuffer += value
            dataBuffer += "\n"
        case "id":
            if !value.contains("\u{0000}") {
                lastEventIdBuffer = value
            }
        case "retry":
            if !value.isEmpty, value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let msec = Int(value) {
                retryTimeHandler?(TimeInterval(msec) / 1000)
            }
        default:
            break // unknown field names are ignored
        }
    }

    // MARK: - Dispatch (spec: "dispatch the event")

    private func dispatchPendingEvent() {
        // Step 1: the last event ID string follows the buffer on every
        // dispatch, including ones that end up not firing an event.
        if lastEventIdBuffer != reportedLastEventId {
            reportedLastEventId = lastEventIdBuffer
            lastEventIdHandler?(lastEventIdBuffer)
        }

        // Step 2: nothing to fire without data.
        if dataBuffer.isEmpty {
            eventTypeBuffer = ""
            return
        }

        // Step 3: strip a single trailing LF.
        if dataBuffer.last == "\n" {
            dataBuffer.removeLast()
        }

        let event = MessageEvent(
            lastEventId: lastEventIdBuffer,
            type: eventTypeBuffer.isEmpty ? "message" : eventTypeBuffer,
            data: dataBuffer
        )
        dataBuffer = ""
        eventTypeBuffer = ""
        eventHandler?(event)
    }
}
