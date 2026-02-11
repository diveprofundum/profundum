import XCTest

final class ProfundumUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTabNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Verify all 4 tabs exist
        XCTAssertTrue(app.tabBars.buttons["Log"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
        XCTAssertTrue(app.tabBars.buttons["Sync"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)

        // Switch between tabs
        app.tabBars.buttons["Library"].tap()
        app.tabBars.buttons["Sync"].tap()
        app.tabBars.buttons["Settings"].tap()
        app.tabBars.buttons["Log"].tap()
    }

    @MainActor
    func testDiveListLoads() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Should see either the dive list or the empty state
        let divesList = app.collectionViews.firstMatch
        let emptyState = app.staticTexts["No Dives"]

        let listOrEmpty = divesList.waitForExistence(timeout: 5) || emptyState.waitForExistence(timeout: 2)
        XCTAssertTrue(listOrEmpty, "Expected either dive list or empty state to appear")
    }

    @MainActor
    func testSettingsViewLoads() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.tabBars.buttons["Settings"].tap()

        // Verify settings controls exist
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
