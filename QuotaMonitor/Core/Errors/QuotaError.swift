//
//  QuotaError.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  统一的配额查询错误类型
//

import Foundation

public enum QuotaError: LocalizedError, Sendable {
    case keyMissing(ProviderKind)
    case keyInvalid(ProviderKind)
    case rateLimited(ProviderKind, retryAfter: TimeInterval?)
    case serverError(ProviderKind, statusCode: Int, message: String?)
    case decodingFailed(ProviderKind, underlying: String)
    case networkUnreachable(ProviderKind, underlying: String? = nil)
    case mockDisabled(ProviderKind)
    case cancelled
    case unknown(ProviderKind, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .keyMissing(let p):
            return "\(p.displayName) 未配置 API Key"
        case .keyInvalid(let p):
            return "\(p.displayName) API Key 无效（401）"
        case .rateLimited(let p, let r):
            if let r {
                return "\(p.displayName) 限流，\(Int(r))s 后重试"
            }
            return "\(p.displayName) 限流"
        case .serverError(let p, let code, let msg):
            return "\(p.displayName) 服务端错误 \(code): \(msg ?? "")"
        case .decodingFailed(let p, let u):
            return "\(p.displayName) 响应解析失败：\(u)"
        case .networkUnreachable(let p, let u):
            if let u {
                return "\(p.displayName) 网络不可达（\(u)）"
            }
            return "\(p.displayName) 网络不可达"
        case .mockDisabled(let p):
            return "\(p.displayName) mock 未启用"
        case .cancelled:
            return "已取消"
        case .unknown(let p, let u):
            return "\(p.displayName) 未知错误：\(u)"
        }
    }

    /// 是否可在下一轮自动重试
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .networkUnreachable:
            return true
        case .serverError(_, let code, _):
            return code >= 500
        default:
            return false
        }
    }

    /// 是否用户可操作（Key 缺失 / 无效），需引导去设置页
    public var isUserActionable: Bool {
        switch self {
        case .keyMissing, .keyInvalid:
            return true
        default:
            return false
        }
    }
}
