import XCTest
import ServiceManagement
@testable import QuotaMonitor

@MainActor
final class LoginItemManagerTests: XCTestCase {
    func testSharedInstanceExists() {
        XCTAssertNotNil(LoginItemManager.shared)
    }

    func testStatusQueryDoesNotCrash() {
        let status = LoginItemManager.shared.status
        // SMAppService.Status has 4 possible values: notRegistered(0), enabled(1), requiresApproval(2), notFound(3)
        XCTAssertTrue([.notRegistered, .enabled, .requiresApproval, .notFound].contains(status))
    }

    func testOpenSystemSettingsURLIsValid() {
        let url = LoginItemManager.systemSettingsURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.hasPrefix("x-apple.systempreferences:") ?? false)
    }
}
