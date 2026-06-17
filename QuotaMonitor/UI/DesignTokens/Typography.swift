//
//  Typography.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  字体令牌：title / heading / body / caption 四级
//

import SwiftUI

public enum Typography {
    public static let title: Font = .system(size: 14, weight: .semibold)
    public static let heading: Font = .system(size: 13, weight: .medium)
    public static let body: Font = .system(size: 12, weight: .regular)
    public static let caption: Font = .system(size: 10, weight: .regular)
}
