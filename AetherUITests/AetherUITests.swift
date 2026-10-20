import XCTest

final class AetherUITests: XCTestCase {
    @MainActor
    func testLaunchShowsSidebarSections() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Buscar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Master"].exists)
    }
}
