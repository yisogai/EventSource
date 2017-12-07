//
//  EventBuffer.swift
//  EventSource
//
//  Created by yisogai on 2017/11/01.
//  Copyright © 2017年 yisogai. All rights reserved.
//

import Foundation

internal class EventBuffer {
    private struct Constants {
        static let eventDelimiters = ["\r\n", "\n", "\r"].map { "\($0)\($0)".data(using: .utf8)! }
    }
    
    var retryTimeHandler: ((TimeInterval) -> Void)?
    var lastEventIdHandler: ((String?) -> Void)?
    var eventHandler: ((MessageEvent) -> Void)?
    
    private var buffer = Data()
    private var lastEventId: String?
    
    func append(_ data: Data) {
        buffer.append(data)
        extractEvents().forEach(processEvent(_:))
    }
    
    func clearBuffer() {
        buffer = Data()
    }
    
    private func extractEvents() -> [String] {
        let findDelimiter: (Range<Data.Index>) -> Range<Data.Index>? = { searchRange in
            for d in Constants.eventDelimiters {
                if let foundRange = self.buffer.range(of: d, options: [], in: searchRange) {
                    return foundRange
                }
            }
            return nil
        }
        
        var events: [String] = []
        
        var searchRange = Range(uncheckedBounds: (lower: 0, upper: buffer.count))
        while let delimiterRange = findDelimiter(searchRange) {
            if delimiterRange.lowerBound > searchRange.lowerBound {
                let eventData = buffer.subdata(in: Range(uncheckedBounds: (lower: searchRange.lowerBound, upper: delimiterRange.lowerBound)))
                if let event = String(data: eventData, encoding: .utf8) {
                    events.append(event)
                }
            }
            
            searchRange = Range(uncheckedBounds: (lower: delimiterRange.upperBound, upper: buffer.count))
        }
        
        buffer.removeSubrange(Range.init(uncheckedBounds: (lower: 0, upper: searchRange.lowerBound)))
        
        return events
    }
    
    private func processEvent(_ rawEvent: String) {
        var type = "message"
        var data = ""
        
        let regex = try! NSRegularExpression(pattern: "(.+?):\\s?(.*)", options: [])
        rawEvent.enumerateLines { line, _ in
            if
                let result = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.count)),
                result.numberOfRanges > 2 {
                
                let nsline = line as NSString
                let key = nsline.substring(with: result.range(at: 1))
                let value: String? = {
                    let value = nsline.substring(with: result.range(at: 2))
                    return value.isEmpty ? nil : value
                }()
                
                switch key {
                case "event":
                    if let value = value {
                        type = value
                    }
                case "data":
                    data += (value ?? "")
                    data += "\n"
                case "id":
                    self.lastEventId = value
                    self.lastEventIdHandler?(value)
                case "retry":
                    self.applyRetryValue(value)
                default:
                    break
                }
            }
        }
        
        if data.isEmpty {
            return
        }
        
        if data.last == "\n" {
            data = String(data.prefix(data.count - 1))
        }
        
        let event = MessageEvent(lastEventId: lastEventId, type: type, data: data)
        eventHandler?(event)
    }
    
    private func applyRetryValue(_ value: String?) {
        if
            let value = value,
            let msec = Int(value) {
            let retry = TimeInterval(msec) / 1000
            retryTimeHandler?(retry)
        }
    }
}
