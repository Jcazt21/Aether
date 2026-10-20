import XCTest

final class AetherUITests: XCTestCase {
    @MainActor
    func testLaunchShowsSidebarSections() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Buscar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Master"].exists)
    }

    @MainActor
    func testQueueShowsEmptyStateAndShortcut() {
        let app = XCUIApplication()
        app.launch()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Cola vacía"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAccessibilityAuditOnEveryScreen() throws {
        let app = XCUIApplication()
        app.launch()
        for key in ["1", "2", "3"] {
            app.typeKey(key, modifierFlags: .command)
            try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription])
        }
    }
}
