//
//  VolcengineSignerTests.swift
//  QuotaMonitorTests
//
//  火山引擎 V4 签名确定性测试。
//  对照 CC Switch src-tauri/src/services/coding_plan.rs volcengine_sign 单测。
//

import XCTest
@testable import QuotaMonitor

final class VolcengineSignerTests: XCTestCase {

    /// 固定时间便于确定性断言
    private func fixedNow() -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.date(from: "2024-06-21T00:00:00Z")!
    }

    func testCanonicalQuery_isSortedAndEncoded() {
        // 按 key 字母序：Action < Region < Version；值含 `-` 属 unreserved，不编码
        let q = VolcengineSigner.canonicalQuery(action: "GetAFPUsage", region: "cn-beijing")
        XCTAssertEqual(q, "Action=GetAFPUsage&Region=cn-beijing&Version=2024-01-01")
    }

    func testSign_structureAndDeterminism() {
        let now = fixedNow()
        let region = "cn-beijing"
        let signed = VolcengineSigner.sign(
            accessKeyId: "AKLTtest",
            secretAccessKey: "secretkey",
            region: region,
            action: "GetAFPUsage",
            body: Data(),
            now: now
        )

        // 空 body 的 SHA-256（固定值），证明走的是空 body
        XCTAssertEqual(
            signed.xContentSha256,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )

        // X-Date 形如 20240621T000000Z
        XCTAssertEqual(signed.xDate, "20240621T000000Z")

        // Authorization 结构：算法无 AWS4 前缀、scope 结尾 ark/request、固定 SignedHeaders
        XCTAssertTrue(
            signed.authorization.hasPrefix("HMAC-SHA256 Credential=AKLTtest/20240621/cn-beijing/ark/request,"),
            "unexpected credential/scope: \(signed.authorization)"
        )
        XCTAssertTrue(
            signed.authorization.contains("SignedHeaders=host;x-date;x-content-sha256;content-type,"),
            "unexpected signed headers: \(signed.authorization)"
        )

        // Signature 是 64 位十六进制
        let sig = signed.authorization.components(separatedBy: "Signature=").last!
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(sig.allSatisfy { $0.isHexDigit })

        // 确定性：同输入同输出
        let signed2 = VolcengineSigner.sign(
            accessKeyId: "AKLTtest",
            secretAccessKey: "secretkey",
            region: region,
            action: "GetAFPUsage",
            body: Data(),
            now: now
        )
        XCTAssertEqual(signed.authorization, signed2.authorization)
    }

    func testRegionExtraction() {
        XCTAssertEqual(
            VolcengineProvider.region(from: "https://ark.cn-beijing.volces.com/api/coding"),
            "cn-beijing"
        )
        XCTAssertEqual(
            VolcengineProvider.region(from: "https://ark.cn-shanghai.volces.com/api/coding/v3"),
            "cn-shanghai"
        )
        // 无可识别 region 段时回落默认 cn-beijing
        XCTAssertEqual(
            VolcengineProvider.region(from: "https://example.com/api/coding"),
            "cn-beijing"
        )
    }
}

private extension Character {
    var isHexDigit: Bool {
        self.isASCII && (isNumber || "abcdefABCDEF".contains(self))
    }
}
