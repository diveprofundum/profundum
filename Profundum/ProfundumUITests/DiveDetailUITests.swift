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
    /// Uses firstMatch to handle sites that appear in multiple dive rows.
    @MainActor
    private func launchAndNavigateToDive(site: String) -> XCUIApplication {
        let app = XCUIApplication.launchForTesting()

        let list = app.collectionViews["diveList"]
        list.assertExists(timeout: 5)

        // Find the first cell containing the site name and tap it.
        // Use firstMatch because a site may appear in multiple dive rows.
        let siteLabel = list.staticTexts[site].firstMatch
        XCTAssertTrue(
            siteLabel.waitForExistence(timeout: 3),
            "Expected dive with site '\(site)' in list"
        )
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

        // Scroll to bottom to find CCR sections
        let scrollView = app.scrollViews.firstMatch
        scrollView.swipeUp()
        scrollView.swipeUp()

        // CCR dives should show CCR Information section
        let ccrHeading = app.staticTexts["CCR Information"]
        ccrHeading.assertExists(timeout: 5)
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
    func testDiveDetailShowsDecoStats() throws {
        // Andrea Doria is the deco dive in sample data — it has deco time
        // computed by DiveStats (shown in Advanced Stats) even though the
        // dive model fields (decoModel, gfLow) may not be set.
        let app = launchAndNavigateToDive(site: "Andrea Doria")

        // Scroll down to Advanced Stats section
        let scrollView = app.scrollViews.firstMatch
        scrollView.swipeUp()

        // Deco Time stat card should be visible in Advanced Stats
        let decoTime = app.staticTexts["Deco Time"]
        decoTime.assertExists(timeout: 5)
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
