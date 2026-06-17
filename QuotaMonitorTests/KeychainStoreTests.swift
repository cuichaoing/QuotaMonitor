//
//  KeychainStoreTests.swift
//  QuotaMonitorTests
//
//  验证 InMemoryKeychainStore 的 CRUD 行为（与生产 KeychainStore 行为一致）
//

import XCTest
@testable import QuotaMonitor

final class KeychainStoreTests: XCTestCase {
    func testSaveReadDelete() throws {
        let store = InMemoryKeychainStore()
        let provider = ProviderKind.kimi

        XCTAssertNil(try store.read(for: provider))
        XCTAssertFalse(store.exists(for: provider))

        try store.save("test-key-123", for: provider)
        XCTAssertTrue(store.exists(for: provider))
        XCTAssertEqual(try store.read(for: provider), "test-key-123")

        try store.delete(for: provider)
        XCTAssertNil(try store.read(for: provider))
        XCTAssertFalse(store.exists(for: provider))
    }

    func testDeleteNonExistent_doesNotThrow() throws {
        let store = InMemoryKeychainStore()
        XCTAssertNoThrow(try store.delete(for: .glm))
    }

    func testMultipleProviders_isolated() throws {
        let store = InMemoryKeychainStore()
        try store.save("kimi-key", for: .kimi)
        try store.save("minimax-key", for: .minimax)
        try store.save("glm-key", for: .glm)

        XCTAssertEqual(try store.read(for: .kimi), "kimi-key")
        XCTAssertEqual(try store.read(for: .minimax), "minimax-key")
        XCTAssertEqual(try store.read(for: .glm), "glm-key")

        // 删除一个不影响其他
        try store.delete(for: .kimi)
        XCTAssertNil(try store.read(for: .kimi))
        XCTAssertEqual(try store.read(for: .minimax), "minimax-key")
        XCTAssertEqual(try store.read(for: .glm), "glm-key")
    }

    func testOverwriteKey() throws {
        let store = InMemoryKeychainStore()
        try store.save("v1", for: .kimi)
        try store.save("v2", for: .kimi)
        XCTAssertEqual(try store.read(for: .kimi), "v2", "save 应覆盖而非追加")
    }

    func testEmptyKey_allowed() throws {
        let store = InMemoryKeychainStore()
        try store.save("", for: .kimi)
        XCTAssertEqual(try store.read(for: .kimi), "")
    }

    func testSpecialCharactersInKey() throws {
        let store = InMemoryKeychainStore()
        let key = "sk-!@#$%^&*()_+-={}[]|:;\"'<>,.?/"
        try store.save(key, for: .kimi)
        XCTAssertEqual(try store.read(for: .kimi), key)
    }
}
