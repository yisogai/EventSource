//
//  MessageEvent.swift
//  EventSource
//
//  Created by yisogai on 2017/11/01.
//  Copyright © 2017年 yisogai. All rights reserved.
//

import Foundation

public struct MessageEvent: Equatable, Sendable {
    public let lastEventId: String?
    public let type: String
    public let data: String

    public init(lastEventId: String?, type: String, data: String) {
        self.lastEventId = lastEventId
        self.type = type
        self.data = data
    }
}
