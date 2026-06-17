//
//  ProviderKind.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  三大平台枚举 + 默认配置
//

import Foundation

public enum ProviderKind: String, CaseIterable, Codable, Sendable {
    case kimi
    case minimax
    case glm

    public var displayName: String {
        switch self {
        case .kimi:    return "Kimi Code"
        case .minimax: return "MiniMax"
        case .glm:     return "Zhipu GLM"
        }
    }

    public var shortName: String {
        switch self {
        case .kimi:    return "K"
        case .minimax: return "M"
        case .glm:     return "G"
        }
    }

    public var defaultBaseURL: URL {
        switch self {
        case .kimi:    return URL(string: "https://api.kimi.com")!
        case .minimax: return URL(string: "https://api.minimax.io")!
        case .glm:     return URL(string: "https://api.z.ai")!
        }
    }

    /// 状态栏上的显示顺序（K -> M -> G 字母序）
    public var sortOrder: Int {
        switch self {
        case .kimi:    return 0
        case .minimax: return 1
        case .glm:     return 2
        }
    }

    /// User-Agent 鉴权需要（仅 Kimi 强依赖）
    public var requiredUserAgent: String? {
        switch self {
        case .kimi:    return "KimiCLI/1.30.0"
        default:       return nil
        }
    }

    /// 鉴权是否需要 Bearer 前缀（GLM 禁用！）
    public var requiresBearerPrefix: Bool {
        switch self {
        case .glm:     return false
        default:       return true
        }
    }
}
