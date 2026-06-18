//
//  DiagHistoryStoreTests.swift
//  QuotaMonitorTests
//
//  验证诊断轨迹 ring buffer
//

import XCTest
@testable import QuotaMonitor

final class DiagHistoryStoreTests: XCTestCase {
    func testAppend_andRecent_returnsAll() {
        let store = DiagHistoryStore()
        let now = Date()
        store.append(DiagEntry(at: now, results: [.kimi: .ok(usedPercent: 17)]))
        store.append(DiagEntry(at: now, results: [.kimi: .ok(usedPercent: 18)]))

        let recent = store.recent(since: now.addingTimeInterval(-60))
        XCTAssertEqual(recent.count, 2)
    }

    func testCap_dropsOldestBeyond20() {
        let store = DiagHistoryStore()
        let base = Date()
        for i in 0..<25 {
            store.append(DiagEntry(at: base.addingTimeInterval(TimeInterval(i)),
                                   results: [.kimi: .ok(usedPercent: Double(i))]))
        }
        let recent = store.recent(since: base.addingTimeInterval(-1))
        XCTAssertEqual(recent.count, 20, "cap=20，超出应淘汰最旧")
        XCTAssertEqual(recent.first?.results[.kimi], .ok(usedPercent: 5), "最旧保留的是第 6 条")
    }

    func testRecent_filtersByCutoff() {
        let store = DiagHistoryStore()
        let old = Date().addingTimeInterval(-600)   // 10 分钟前
        let now = Date()
        store.append(DiagEntry(at: old, results: [.glm: .ok(usedPercent: 1)]))
        store.append(DiagEntry(at: now, results: [.glm: .ok(usedPercent: 2)]))

        let within5min = store.recent(since: now.addingTimeInterval(-300))
        XCTAssertEqual(within5min.count, 1, "5 分钟外的条目应被过滤")
    }

    func testOutcome_errorCase_carriesType() {
        let outcome = DiagProviderOutcome.error(type: "networkUnreachable")
        XCTAssertEqual(outcome, .error(type: "networkUnreachable"))
    }
}
