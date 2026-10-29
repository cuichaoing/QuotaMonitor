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
    /// 网页会话型平台：不走 API Key，走 Google 网页登录（GeminiSessionManager）
    case gemini

    public var displayName: String {
        switch self {
        case .kimi:    return "Kimi Code"
        case .minimax: return "MiniMax"
        case .glm:     return "Zhipu GLM"
        case .gemini:  return "Google Gemini"
        }
    }

    public var shortName: String {
        switch self {
        case .kimi:    return "K"
        case .minimax: return "M"
        case .gemini:  return "G"   // Google Gemini
        case .glm:     return "Z"   // 智谱 Zhipu（原用 G，与 Gemini 冲突，v1.1.1 改名）
        }
    }

    public var defaultBaseURL: URL {
        switch self {
        case .kimi:    return URL(string: "https://api.kimi.com")!
        case .minimax: return URL(string: "https://api.minimax.io")!
        case .glm:     return URL(string: "https://api.z.ai")!
        case .gemini:  return URL(string: "https://gemini.google.com")!
        }
    }

    /// 状态栏上的显示顺序（K -> M -> G -> Z）
    public var sortOrder: Int {
        switch self {
        case .kimi:    return 0
        case .minimax: return 1
        case .gemini:  return 2   // G（Google）
        case .glm:     return 3   // Z（智谱）
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
