//
//  GeminiSessionTests.swift
//  QuotaMonitorTests
//
//  Gemini 网页会话通道的接入验证：
//   - 分流正确：走会话通道而非 Keychain（无 Key 也能出数）
//   - 错误透传：sessionMissing / sessionExpired 原样上抛
//

import XCTest
@testable import QuotaMonitor

final class GeminiSessionTests: XCTestCase {

    /// 会话通道 mock（不碰真实 WebKit）
    private struct MockGeminiSession: GeminiSessionProviding {
        let result: Result<ProviderQuota, QuotaError>
        func fetchQuota() async throws -> ProviderQuota {
            switch result {
            case .success(let q): return q
            case .failure(let e): throw e
            }
        }
    }

    private func makeQuota(percent: Double) -> ProviderQuota {
        ProviderQuota(
            provider: .gemini,
            primaryWindow: QuotaWindow(total: 100, used: percent, resetAt: Date(), displayName: "当前"),
            weeklyWindow: QuotaWindow(total: 100, used: 3, resetAt: Date(), displayName: "每周"))
    }

    /// 无 Key 也能取到数：Gemini 不走 Keychain
    func testFetchOne_gemini_worksWithoutAPIKey() async {
        let service = NetworkingService(
            keychain: InMemoryKeychainStore(),
            httpClient: MockURLProtocol.makeHTTPClient(),
            geminiSession: MockGeminiSession(result: .success(makeQuota(percent: 31))))

        let result = await service.fetchOne(.gemini)
        guard case .success(let quota) = result else {
            return XCTFail("期望成功，实际 \(result)")
        }
        XCTAssertEqual(quota.provider, .gemini)
        XCTAssertEqual(quota.primaryUsedPercent, 31)
        XCTAssertEqual(quota.weeklyWindow?.usedPercent, 3)
    }

    func testFetchOne_gemini_sessionMissing_propagates() async {
        let service = NetworkingService(
            keychain: InMemoryKeychainStore(),
            httpClient: MockURLProtocol.makeHTTPClient(),
            geminiSession: MockGeminiSession(result: .failure(.sessionMissing(.gemini))))

        let result = await service.fetchOne(.gemini)
        guard case .failure(let err) = result else {
            return XCTFail("期望失败，实际 \(result)")
        }
        XCTAssertEqual(err.localizedDescription, "Google Gemini 尚未登录网页版")
        XCTAssertTrue(err.isUserActionable)
    }

    func testFetchOne_gemini_sessionExpired_propagates() async {
        let service = NetworkingService(
            keychain: InMemoryKeychainStore(),
            httpClient: MockURLProtocol.makeHTTPClient(),
            geminiSession: MockGeminiSession(result: .failure(.sessionExpired(.gemini))))

        let result = await service.fetchOne(.gemini)
        guard case .failure(let err) = result else {
            return XCTFail("期望失败，实际 \(result)")
        }
        XCTAssertTrue(err.isUserActionable)
        XCTAssertTrue(err.isRetryable, "过期后每轮仍可重试（Google 侧可能自愈）")
    }

    /// 状态栏字母：K=Kimi M=MiniMax G=Google Gemini Z=智谱 GLM
    func testProviderKind_lettersAndOrder() {
        let sorted = ProviderKind.allCases.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(sorted, [.kimi, .minimax, .gemini, .glm])
        XCTAssertEqual(ProviderKind.kimi.shortName, "K")
        XCTAssertEqual(ProviderKind.minimax.shortName, "M")
        XCTAssertEqual(ProviderKind.gemini.shortName, "G")
        XCTAssertEqual(ProviderKind.glm.shortName, "Z")
        XCTAssertEqual(ProviderKind.gemini.displayName, "Google Gemini")
    }
}
