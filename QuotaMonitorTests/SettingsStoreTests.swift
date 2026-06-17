//
//  SettingsStoreTests.swift
//  QuotaMonitorTests
//
//  SettingsStore 单元测试：Keychain + UserDefaults 行为
//

import XCTest
@testable import QuotaMonitor

@MainActor
final class SettingsStoreTests: XCTestCase {
    var mockKeychain: InMemoryKeychainStore!
    var defaults: UserDefaults!
    var store: SettingsStore!

    override func setUp() async throws {
        try await super.setUp()
        mockKeychain = InMemoryKeychainStore()
        // 用独立 suite 避免污染真实 UserDefaults
        defaults = UserDefaults(suiteName: "test.qm.settings.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().first?.key ?? "")
        store = SettingsStore(keychain: mockKeychain, defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "test.qm.settings")
        store = nil
        mockKeychain = nil
        try await super.tearDown()
    }

    // MARK: - 默认值

    func testDefaults_allProvidersEnabled() {
        XCTAssertEqual(store.enabledProviders, Set(ProviderKind.allCases),
                       "首次启动应默认启用所有平台")
    }

    func testDefaults_thresholdValues() {
        XCTAssertEqual(store.warningThreshold, 75, accuracy: 0.001)
        XCTAssertEqual(store.criticalThreshold, 90, accuracy: 0.001)
        XCTAssertEqual(store.dangerThreshold, 99, accuracy: 0.001)
    }

    func testDefaults_intervalValues() {
        XCTAssertEqual(store.activeInterval, 30, accuracy: 0.001)
        XCTAssertEqual(store.normalInterval, 60, accuracy: 0.001)
        XCTAssertEqual(store.idleInterval, 300, accuracy: 0.001)
    }

    // MARK: - API Key 操作

    func testKeyState_notConfigured_initially() {
        for kind in ProviderKind.allCases {
            XCTAssertEqual(store.keyState(for: kind), .notConfigured)
        }
    }

    func testSaveKey_changesStateToConfigured() throws {
        try store.saveKey("sk-test-123", for: .kimi)
        XCTAssertEqual(store.keyState(for: .kimi), .configured)
    }

    func testSaveKey_trimsWhitespace() throws {
        try store.saveKey("  sk-test-456  \n", for: .kimi)
        let stored = try XCTUnwrap(mockKeychain.read(for: .kimi))
        XCTAssertEqual(stored, "sk-test-456", "前后空白应被 trim")
    }

    func testSaveKey_empty_throwsKeyMissing() {
        XCTAssertThrowsError(try store.saveKey("", for: .kimi))
        XCTAssertThrowsError(try store.saveKey("   \n", for: .kimi))
    }

    func testDeleteKey_resetsState() throws {
        try store.saveKey("k1", for: .kimi)
        XCTAssertEqual(store.keyState(for: .kimi), .configured)

        try store.deleteKey(for: .kimi)
        XCTAssertEqual(store.keyState(for: .kimi), .notConfigured)
    }

    func testDeleteKey_notExists_isNoop() throws {
        // 删除不存在的 key 不应抛错
        XCTAssertNoThrow(try store.deleteKey(for: .kimi))
    }

    // MARK: - 启用平台

    func testToggleEnabled_addsAndRemoves() {
        store.enabledProviders.remove(.kimi)
        XCTAssertFalse(store.enabledProviders.contains(.kimi))

        store.enabledProviders.insert(.kimi)
        XCTAssertTrue(store.enabledProviders.contains(.kimi))
    }

    func testEnabledKinds_sortedBySortOrder() {
        store.enabledProviders = Set(ProviderKind.allCases)
        let kinds = store.enabledKinds()
        // 应该按 sortOrder 升序
        for i in 1..<kinds.count {
            XCTAssertLessThanOrEqual(kinds[i-1].sortOrder, kinds[i].sortOrder)
        }
    }

    func testEnabledKinds_excludesDisabled() {
        store.enabledProviders = [.kimi]
        XCTAssertEqual(store.enabledKinds(), [.kimi])
    }

    func testShouldFetch_requiresEnabledAndConfigured() throws {
        store.enabledProviders = [.kimi]
        XCTAssertFalse(store.shouldFetch(.kimi), "未配 Key")

        try store.saveKey("k1", for: .kimi)
        XCTAssertTrue(store.shouldFetch(.kimi))

        store.enabledProviders.remove(.kimi)
        XCTAssertFalse(store.shouldFetch(.kimi), "未启用")
    }

    // MARK: - UserDefaults 持久化

    func testEnabledProviders_persistsAcrossInstances() {
        store.enabledProviders = [.kimi, .glm]

        // 重新构造 store
        let newStore = SettingsStore(keychain: mockKeychain, defaults: defaults)
        XCTAssertEqual(newStore.enabledProviders, [.kimi, .glm])
    }

    func testThresholds_persistAcrossInstances() {
        store.warningThreshold = 60
        store.criticalThreshold = 80
        store.dangerThreshold = 95

        let newStore = SettingsStore(keychain: mockKeychain, defaults: defaults)
        XCTAssertEqual(newStore.warningThreshold, 60, accuracy: 0.001)
        XCTAssertEqual(newStore.criticalThreshold, 80, accuracy: 0.001)
        XCTAssertEqual(newStore.dangerThreshold, 95, accuracy: 0.001)
    }

    func testIntervals_persistAcrossInstances() {
        store.activeInterval = 15
        store.normalInterval = 45
        store.idleInterval = 120

        let newStore = SettingsStore(keychain: mockKeychain, defaults: defaults)
        XCTAssertEqual(newStore.activeInterval, 15, accuracy: 0.001)
        XCTAssertEqual(newStore.normalInterval, 45, accuracy: 0.001)
        XCTAssertEqual(newStore.idleInterval, 120, accuracy: 0.001)
    }

    // MARK: - 刷新间隔覆盖

    func testIntervalOverride_returnsStoredValue() {
        store.activeInterval = 15
        XCTAssertEqual(store.intervalOverride(for: .active), 15)

        store.normalInterval = 90
        XCTAssertEqual(store.intervalOverride(for: .normal), 90)
    }

    func testIntervalOverride_sleepingAlwaysNil() {
        store.idleInterval = 999
        XCTAssertNil(store.intervalOverride(for: .sleeping),
                     "休眠期永远不应该被定时器唤醒")
    }
}
