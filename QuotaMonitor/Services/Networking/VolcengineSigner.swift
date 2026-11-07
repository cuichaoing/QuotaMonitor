//
//  VolcengineSigner.swift
//  QuotaMonitor
//
//  火山引擎 V4 签名（HMAC-SHA256）——控制面 OpenAPI 鉴权。
//
//  与 Kimi/GLM 的 Bearer Token 完全不同，火山 OpenAPI 强制 V4 签名。
//  算法是 AWS SigV4 的火山变体，照搬标准 SigV4 会签名失败，两处致命差异：
//    1. canonical headers 与 SignedHeaders 用固定顺序
//       `host;x-date;x-content-sha256;content-type`（不按字母序）；
//    2. algorithm 串 `HMAC-SHA256`（无 `AWS4` 前缀）、credential scope 结尾 `request`
//       （非 `aws4_request`）、签名密钥 `kDate=HMAC(SK, date)`（SK 不加 `AWS4` 前缀）。
//
//  对照：CC Switch src-tauri/src/services/coding_plan.rs volcengine_sign 实现。
//

import Foundation
import CryptoKit

public enum VolcengineSigner {
    /// 控制面 OpenAPI 统一网关（区别于数据面推理域名 ark.cn-beijing.volces.com）
    public static let openAPIHost = "open.volcengineapi.com"
    public static let apiVersion = "2024-01-01"
    public static let `service` = "ark"
    public static let contentType = "application/json; charset=utf-8"
    public static let signedHeaders = "host;x-date;x-content-sha256;content-type"

    /// 单次签名结果——三者都要塞进请求头。
    public struct SignedHeaders: Sendable {
        public let authorization: String
        public let xDate: String
        public let xContentSha256: String
        public let canonicalQuery: String
        public let url: URL

        public init(authorization: String, xDate: String, xContentSha256: String,
                    canonicalQuery: String, url: URL) {
            self.authorization = authorization
            self.xDate = xDate
            self.xContentSha256 = xContentSha256
            self.canonicalQuery = canonicalQuery
            self.url = url
        }
    }

    /// 构造按 key 字母序排序、逐段 URL 编码的 canonical query string。
    /// 同一份字符串既用于签名也用于实际请求 URL，保证两者完全一致。
    public static func canonicalQuery(action: String, region: String) -> String {
        let pairs: [(String, String)] = [
            ("Action", action),
            ("Region", region),
            ("Version", apiVersion),
        ]
        return pairs
            .sorted { $0.0 < $1.0 }
            .map { "\(uriEncode($0))=\(uriEncode($1))" }
            .joined(separator: "&")
    }

    /// RFC3986 unreserved 之外全部按 `%XX` 编码（用于 canonical query string）。
    public static func uriEncode(_ input: String) -> String {
        var out = String()
        for byte in input.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// 生成火山引擎签名 V4 的鉴权头。
    /// - Parameters:
    ///   - accessKeyId: 火山账号 AccessKey ID（IAM 获取）
    ///   - secretAccessKey: 火山账号 Secret Access Key
    ///   - region: 控制面 region（从数据面 base_url 提取，如 cn-beijing）
    ///   - action: OpenAPI Action 名（如 GetAFPUsage）
    ///   - body: 请求体（GetAFPUsage 为空 body）
    ///   - now: 签名时间（测试时可注入固定值）
    /// - Returns: 签名后的请求头集合 + 完整 URL
    public static func sign(
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        action: String,
        body: Data,
        now: Date = Date()
    ) -> SignedHeaders {
        let canonicalQuery = canonicalQuery(action: action, region: region)

        // X-Date 格式：20240621T000000Z（UTC）
        let xDate = Self.utcTimestamp(now, format: "yyyyMMdd'T'HHmmss'Z'")
        let shortDate = Self.utcTimestamp(now, format: "yyyyMMdd")
        let xContentSha256 = sha256Hex(body)

        // 固定顺序 canonical headers（火山特有，不排序）
        let canonicalHeaders = """
        host:\(openAPIHost)
        x-date:\(xDate)
        x-content-sha256:\(xContentSha256)
        content-type:\(contentType)
        """ + "\n"

        // canonical headers 块（每行以 \n 结尾，含最后一行）与 signed headers 之间
        // 必须空一行（SigV4 规范）：canonicalHeaders 已带结尾 \n，这里独立一行再补一个 \n。
        let canonicalRequest = """
        POST
        /
        \(canonicalQuery)
        \(canonicalHeaders)
        \(signedHeaders)
        \(xContentSha256)
        """

        let credentialScope = "\(shortDate)/\(region)/\(service)/request"
        let stringToSign = """
        HMAC-SHA256
        \(xDate)
        \(credentialScope)
        \(sha256Hex(canonicalRequest.data(using: .utf8)!))
        """

        // 签名密钥派生：kDate=HMAC(SK, date)（SK 不加 AWS4 前缀），终止串 request
        let kDate = hmacSha256(key: secretAccessKey.data(using: .utf8)!, message: shortDate.data(using: .utf8)!)
        let kRegion = hmacSha256(key: kDate, message: region.data(using: .utf8)!)
        let kService = hmacSha256(key: kRegion, message: service.data(using: .utf8)!)
        let kSigning = hmacSha256(key: kService, message: "request".data(using: .utf8)!)
        let signature = hmacSha256(key: kSigning, message: stringToSign.data(using: .utf8)!)
            .map { String(format: "%02x", $0) }
            .joined()

        let authorization = "HMAC-SHA256 Credential=\(accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        let url = URL(string: "https://\(openAPIHost)/?\(canonicalQuery)")!

        return SignedHeaders(
            authorization: authorization,
            xDate: xDate,
            xContentSha256: xContentSha256,
            canonicalQuery: canonicalQuery,
            url: url
        )
    }

    // MARK: - Crypto Helpers

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSha256(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func utcTimestamp(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
