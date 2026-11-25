import XCTest
@testable import CinemacoreCore

final class AppVersionTests: XCTestCase {
    func testDisplayFormat() {
        let version = AppVersion(full: "0.0.1-beta.1", build: "131", commit: "abc1234")
        XCTAssertEqual(version.display, "v0.0.1-beta.1 (131) abc1234")
    }

    func testBundleFallbackIsDev() {
        let version = AppVersion(bundle: Bundle(for: AppVersionTests.self))
        XCTAssertFalse(version.display.isEmpty)
        XCTAssertTrue(version.display.hasPrefix("v"))
    }
}
