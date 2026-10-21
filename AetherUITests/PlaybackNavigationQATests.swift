import XCTest

/// Regression for the "no subgraph" crash: navigate every sidebar screen while audio is playing.
final class PlaybackNavigationQATests: XCTestCase {
    @MainActor
    func testNavigatingEverySidebarItemWhilePlaying() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Master"].waitForExistence(timeout: 10))
        app.staticTexts["Master"].click()

        let firstRow = app.tables.firstMatch.tableRows.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "Master has no tracks to play")
        firstRow.doubleClick()
        sleep(2)

        let items = ["Cola", "Historial", "Por clasificar", "Sin tags", "Duplicados", "Lossy", "Master", "Buscar"]
        for round in 1...3 {
            for name in items {
                let item = app.staticTexts[name]
                XCTAssertTrue(item.waitForExistence(timeout: 5), "\(name) missing in round \(round)")
                item.click()
                usleep(600_000)
                XCTAssertEqual(app.state, .runningForeground, "App died after opening \(name) in round \(round)")
            }
        }
    }
}
