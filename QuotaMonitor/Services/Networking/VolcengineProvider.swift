//
//  VolcengineProvider.swift
//  QuotaMonitor
//
//  火山方舟 Agent Plan 配额查询（控制面 OpenAPI + AK/SK V4 签名）。
//
//  与 Kimi/GLM（数据面 Bearer Key）不同，火山用量接口是控制面 OpenAPI：
//    - 端点：POST https://open.volcengineapi.com/?Action=GetAFPUsage&Region=cn-beijing&Version=2024-01-01
//    - 鉴权：火山引擎 V4 签名（AK/SK），见 VolcengineSigner
//    - 响应：Result.AFPFiveHour.{Quota, Used, ResetTime}（绝对 AFP 值）
//    - 已用百分比 = Used / Quota × 100
//    - 降级：AFPFiveHour Quota<=0（未订阅 Agent Plan）→ 再调 GetCodingPlanUsage（回百分比）
//

import Foundation

public enum VolcengineProvider {
    /// 从数据面 base_url 提取控制面 OpenAPI 所需的 Region（如 ark.cn-beijing.volces.com → cn-beijing）；
    /// 无法识别时回落 cn-beijing。
    public static func region(from baseURL: String) -> String {
        let host = baseURL
            .split(separator: "://")
            .last
            .map(String.init)
            .flatMap { $0.split(separator: "/").first.map(String.init) }
            ?? baseURL
        for part in host.split(separator: ".") {
            if part.hasPrefix("cn-") || part.hasPrefix("ap-") {
                return String(part)
            }
        }
        return "cn-beijing"
    }

    /// 单次查询 Agent Plan 配额。
    public static func fetchQuota(
        accessKeyId: String,
        secretAccessKey: String,
        dataBaseURL: String,
        using client: HTTPClient
    ) async throws -> ProviderQuota {
        let region = region(from: dataBaseURL)

        // 1) Agent Plan：GetAFPUsage
        //    区分「真未订阅（Quota<=0，应降级）」与「请求失败（应透传真实错误）」
        do {
            if let quota = try await fetchAFPUsage(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                region: region,
                using: client
            ) {
                return quota
            }
            // AFP 返回 nil = Quota<=0 未订阅，降级 Coding Plan
        } catch let err as VolcError {
            // AFP 请求层失败（非 2xx / 网关错误）→ 透传，不再降级掩盖
            throw QuotaError.serverError(.volcengine, statusCode: err.statusCode, message: err.detail)
        }

        // 2) Coding Plan：GetCodingPlanUsage（降级）
        do {
            if let quota = try await fetchCodingPlanUsage(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                region: region,
                using: client
            ) {
                return quota
            }
        } catch let err as VolcError {
            throw QuotaError.serverError(.volcengine, statusCode: err.statusCode, message: err.detail)
        }

        throw QuotaError.decodingFailed(.volcengine, underlying: "GetAFPUsage 与 GetCodingPlanUsage 均未返回可解析的额度")
    }

    /// 内部错误：携带真实 HTTP 状态码 + 响应体摘要（用于诊断签名/网关问题）
    struct VolcError: Error {
        let statusCode: Int
        let detail: String
    }

    // MARK: - GetAFPUsage（Agent Plan）

    private static func fetchAFPUsage(
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        using client: HTTPClient
    ) async throws -> ProviderQuota? {
        let signed = VolcengineSigner.sign(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            region: region,
            action: "GetAFPUsage",
            body: Data()
        )

        // 注意：不手动设 Host——URLSession 会从 URL 自动设，手动设可能导致重复头。
        let request = HTTPRequest(
            url: signed.url,
            method: "POST",
            headers: [
                "X-Date": signed.xDate,
                "X-Content-Sha256": signed.xContentSha256,
                "Content-Type": VolcengineSigner.contentType,
                "Authorization": signed.authorization,
            ]
        )

        let response = try await client.send(request)

        // 非 2xx：透传状态码 + 响应体摘要（网关签名错误通常 400 + ResponseMetadata.Error）
        guard 200...299 ~= response.statusCode else {
            let bodyText = String(data: response.data, encoding: .utf8) ?? "<非 UTF8>"
            throw VolcError(statusCode: response.statusCode, detail: "HTTP \(response.statusCode): \(bodyText.prefix(300))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw VolcError(statusCode: response.statusCode, detail: "非 JSON 对象: \(String(data: response.data, encoding: .utf8)?.prefix(200) ?? "")")
        }

        // 火山 OpenAPI 业务错误常以 200 + ResponseMetadata.Error 返回
        if let errMeta = json["ResponseMetadata"] as? [String: Any],
           let error = errMeta["Error"] as? [String: Any],
           let code = error["Code"] as? String {
            let msg = error["Message"] as? String ?? ""
            throw VolcError(statusCode: 200, detail: "\(code): \(msg)")
        }

        let result = json["Result"] as? [String: Any] ?? json

        // 解析 5h 窗口
        guard let fiveHour = result["AFPFiveHour"] as? [String: Any] else { return nil }
        let quota = KimiProvider.numericValue(fiveHour["Quota"]) ?? 0
        guard quota > 0 else { return nil }   // Quota<=0 = 未订阅该窗口，降级

        let used = KimiProvider.numericValue(fiveHour["Used"]) ?? 0
        let usedPercent = used / quota * 100
        let resetAt = extractResetTime(fiveHour["ResetTime"])
            ?? Date().addingTimeInterval(5 * 3600)

        let primaryWindow = QuotaWindow(
            total: 100,
            used: usedPercent,
            resetAt: resetAt,
            displayName: "5h"
        )

        // 周窗口（副窗口）
        let weeklyWindow: QuotaWindow? = {
            guard let weekly = result["AFPWeekly"] as? [String: Any],
                  let wQuota = KimiProvider.numericValue(weekly["Quota"]), wQuota > 0,
                  let wUsed = KimiProvider.numericValue(weekly["Used"]),
                  let wReset = extractResetTime(weekly["ResetTime"]) else {
                return nil
            }
            return QuotaWindow(
                total: 100,
                used: wUsed / wQuota * 100,
                resetAt: wReset,
                displayName: "7d"
            )
        }()

        return ProviderQuota(
            provider: .volcengine,
            capturedAt: Date(),
            primaryWindow: primaryWindow,
            weeklyWindow: weeklyWindow,
            raw: json
        )
    }

    // MARK: - GetCodingPlanUsage（Coding Plan 降级）

    private static func fetchCodingPlanUsage(
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        using client: HTTPClient
    ) async throws -> ProviderQuota? {
        let signed = VolcengineSigner.sign(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            region: region,
            action: "GetCodingPlanUsage",
            body: Data()
        )

        let request = HTTPRequest(
            url: signed.url,
            method: "POST",
            headers: [
                "X-Date": signed.xDate,
                "X-Content-Sha256": signed.xContentSha256,
                "Content-Type": VolcengineSigner.contentType,
                "Authorization": signed.authorization,
            ]
        )

        let response = try await client.send(request)
        guard 200...299 ~= response.statusCode else {
            let bodyText = String(data: response.data, encoding: .utf8) ?? "<非 UTF8>"
            throw VolcError(statusCode: response.statusCode, detail: "HTTP \(response.statusCode): \(bodyText.prefix(300))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw VolcError(statusCode: response.statusCode, detail: "非 JSON 对象")
        }

        if let errMeta = json["ResponseMetadata"] as? [String: Any],
           let error = errMeta["Error"] as? [String: Any],
           let code = error["Code"] as? String {
            let msg = error["Message"] as? String ?? ""
            throw VolcError(statusCode: 200, detail: "\(code): \(msg)")
        }

        let result = json["Result"] as? [String: Any] ?? json

        guard let usages = result["QuotaUsage"] as? [[String: Any]] else { return nil }

        guard let session = usages.first(where: {
            ($0["Level"] as? String)?.lowercased() == "session"
        }) else { return nil }

        let usedPercent = KimiProvider.numericValue(session["Percent"]) ?? 0
        let resetAt = extractResetTime(session["ResetTimestamp"] ?? session["ResetTime"])
            ?? Date().addingTimeInterval(5 * 3600)

        let primaryWindow = QuotaWindow(
            total: 100,
            used: usedPercent,
            resetAt: resetAt,
            displayName: "5h"
        )

        let weeklyWindow: QuotaWindow? = {
            guard let weekly = usages.first(where: {
                ($0["Level"] as? String)?.lowercased() == "weekly"
            }) else { return nil }
            let pct = KimiProvider.numericValue(weekly["Percent"]) ?? 0
            let reset = extractResetTime(weekly["ResetTimestamp"] ?? weekly["ResetTime"])
                ?? Date().addingTimeInterval(7 * 24 * 3600)
            return QuotaWindow(total: 100, used: pct, resetAt: reset, displayName: "7d")
        }()

        return ProviderQuota(
            provider: .volcengine,
            capturedAt: Date(),
            primaryWindow: primaryWindow,
            weeklyWindow: weeklyWindow,
            raw: json
        )
    }

    // MARK: - Helpers

    /// 兼容秒/毫秒/字符串时间戳。秒级（< 1e12）自动乘 1000；<= 0 视为无重置时间。
    private static func extractResetTime(_ any: Any?) -> Date? {
        if let s = any as? String {
            return KimiProvider.parseResetTime(s)
        }
        guard let ms = KimiProvider.numericValue(any) else { return nil }
        guard ms > 0 else { return nil }
        let seconds = ms < 1_000_000_000_000 ? ms / 1000 : ms
        return Date(timeIntervalSince1970: seconds)
    }
}
