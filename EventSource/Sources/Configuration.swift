//
//  Configuration.swift
//  EventSource
//
//  Created by yisogai on 2017/11/01.
//  Copyright © 2017年 yisogai. All rights reserved.
//

import Foundation

public struct Configuration {
    let headers: [String: String]
    let lastEventId: String?
    let retryTime: TimeInterval
    
    public init(
        headers: [String: String] = [:],
        lastEventId: String?      = nil,
        retryTime: TimeInterval   = 3
        ) {
        self.headers = headers
        self.lastEventId = lastEventId
        self.retryTime = retryTime
    }
}
