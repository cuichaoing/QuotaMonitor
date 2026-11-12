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
    /// 火山方舟 Agent Plan：控制面 OpenAPI + AK/SK V4 签名（不走数据面 Bearer Key）
    case volcengine
    /// 百度千帆 Token Plan：网页会话型，走百度账号登录 + 控制台「我的订阅」页抓取（BaiduSessionManager）
    case baidu

    public var displayName: String {
        switch self {
        case .kimi:       return "Kimi Code"
        case .minimax:    return "MiniMax"
        case .glm:        return "Zhipu GLM"
        case .gemini:     return "Google Gemini"
        case .volcengine: return "火山引擎"
        case .baidu:      return "百度千帆"
        }
    }

    public var shortName: String {
        switch self {
        case .kimi:       return "K"
        case .minimax:    return "M"
        case .gemini:     return "G"   // Google Gemini
        case .glm:        return "Z"   // 智谱 Zhipu（原用 G，与 Gemini 冲突，v1.1.1 改名）
        case .volcengine: return "V"   // 火山 Volcengine
        case .baidu:      return "B"   // 百度千帆 Baidu Qianfan
        }
    }

    public var defaultBaseURL: URL {
        switch self {
        case .kimi:       return URL(string: "https://api.kimi.com")!
        case .minimax:    return URL(string: "https://api.minimax.io")!
        case .glm:        return URL(string: "https://api.z.ai")!
        case .gemini:     return URL(string: "https://gemini.google.com")!
        case .volcengine: return URL(string: "https://open.volcengineapi.com")!
        case .baidu:      return URL(string: "https://console.bce.baidu.com/qianfan/resource/token-plan")!
        }
    }

    /// 状态栏上的显示顺序（K -> M -> G -> Z -> V）
    public var sortOrder: Int {
        switch self {
        case .kimi:       return 0
        case .minimax:    return 1
        case .gemini:     return 2   // G（Google）
        case .glm:        return 3   // Z（智谱）
        case .volcengine: return 4   // V（火山）
        case .baidu:      return 5   // B（百度千帆）
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
