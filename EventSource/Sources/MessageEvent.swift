//
//  MessageEvent.swift
//  EventSource
//
//  Created by yisogai on 2017/11/01.
//  Copyright © 2017年 yisogai. All rights reserved.
//

import Foundation

public struct MessageEvent {
    public let lastEventId: String?
    public let type: String
    public let data: String
}
