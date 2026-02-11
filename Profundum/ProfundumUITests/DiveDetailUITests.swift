import XCTest

final class DiveDetailUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Helper: launch, wait for list, tap first dive to navigate to detail.
    @MainActor
    private func launchAndNavigateToFirstDive() -> XCUIApplication {
        let app = XCUIApplication.launchForTesting()

        let list = app.collectionViews["diveList"]
        list.assertExists(timeout: 5)

        let firstCell = list.cells.element(boundBy: 0)
        XCTAssertTrue(firstCell.waitForExistence(timeout: 3))
        firstCell.tap()

        return app
    }

    /// Helper: navigate to a dive whose row contains the given site name.
    @MainActor
    private func launchAndNavigateToDive(site: String) -> XCUIApplication {
        let app = XCUIApplication.launchForTesting()

        let list = app.collectionViews["diveList"]
        list.assertExists(timeout: 5)

        // Find a cell containing the site name and tap it
        let siteLabel = list.staticTexts[site]
        siteLabel.assertExists(timeout: 3, "Expected dive with site '\(site)' in list")
        siteLabel.tap()

        return app
    }

    // MARK: - Tests

    @MainActor
    func testDiveDetailShowsHeaderAndStats() throws {
        let app = launchAndNavigateToFirstDive()

        // Stat cards should be visible
        let maxDepth = app.staticTexts["Max Depth"]
        maxDepth.assertExists(timeout: 5)

        let avgDepth = app.staticTexts["Avg Depth"]
        avgDepth.assertExists()

        let bottomTime = app.staticTexts["Bottom Time"]
        bottomTime.assertExists()
    }

    @MainActor
    func testDiveDetailShowsCCRSections() throws {
        // Navigate to a CCR dive (Ginnie Springs is CCR in sample data)
        let app = launchAndNavigateToDive(site: "Ginnie Springs - Ballroom")

        // Wait for detail to load
        sleep(1)

        // CCR dives should show CCR Information section
        let ccrHeading = app.staticTexts["CCR Information"]
        ccrHeading.assertExists(timeout: 5)

        // PPO2 section should also appear for CCR dives with sensor data
        let ppo2Heading = app.staticTexts["PPO2 Sensors"]
        // PPO2 may or may not be visible depending on scroll position,
        // so scroll down to find it
        let scrollView = app.scrollViews.firstMatch
        scrollView.swipeUp()
        ppo2Heading.assertExists(timeout: 3)
    }

    @MainActor
    func testDiveDetailShowsDepthProfileChart() throws {
        let app = launchAndNavigateToFirstDive()

        // Scroll to find Depth Profile section
        let scrollView = app.scrollViews.firstMatch
        scrollView.swipeUp()

        // Section heading
        let heading = app.staticTexts["Depth Profile"]
        heading.assertExists(timeout: 5)

        // Chart element via accessibility identifier
        let chart = app.otherElements["depthProfileChart"]
        chart.assertExists()
    }

    @MainActor
    func testDiveDetailShowsDecoSection() throws {
        // Andrea Doria is the deco dive in sample data
        let app = launchAndNavigateToDive(site: "Andrea Doria")

        // Decompression section should be visible (may need scroll)
        let decoHeading = app.staticTexts["Decompression"]
        if !decoHeading.waitForExistence(timeout: 3) {
            app.scrollViews.firstMatch.swipeUp()
        }
        decoHeading.assertExists(timeout: 3)
    }

    @MainActor
    func testDiveDetailEditButton() throws {
        let app = launchAndNavigateToFirstDive()

        // Edit button should exist in toolbar
        let editButton = app.buttons["editDiveButton"]
        editButton.assertExists(timeout: 5)
        editButton.tap()

        // Edit sheet should show "Edit Dive" title
        let editTitle = app.staticTexts["Edit Dive"]
        editTitle.assertExists(timeout: 3)

        // Dismiss the sheet
        let cancelButton = app.buttons["cancelButton"]
        cancelButton.assertExists()
        cancelButton.tap()
    }
}
