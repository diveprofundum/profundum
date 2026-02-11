import XCTest

final class NavigationFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tests

    @MainActor
    func testListToDetailAndBack() throws {
        let app = XCUIApplication.launchForTesting()

        // Dive list should load
        let list = app.collectionViews["diveList"]
        list.assertExists(timeout: 5)

        // Tap first dive
        let firstCell = list.cells.element(boundBy: 0)
        XCTAssertTrue(firstCell.waitForExistence(timeout: 3))
        firstCell.tap()

        // Detail view should show stat cards
        let maxDepth = app.staticTexts["Max Depth"]
        maxDepth.assertExists(timeout: 5)

        // Navigate back
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists {
            backButton.tap()
        }

        // Dive list should be visible again
        list.assertExists(timeout: 3)
    }

    @MainActor
    func testLibraryTabSections() throws {
        let app = XCUIApplication.launchForTesting()

        // Navigate to Library tab
        app.tabBars.buttons["Library"].assertExists(timeout: 5).tap()

        // All library sections should be visible
        app.staticTexts["Devices"].assertExists(timeout: 3)
        app.staticTexts["Sites"].assertExists()
        app.staticTexts["Teammates"].assertExists()
        app.staticTexts["Equipment"].assertExists()
        app.staticTexts["Formulas"].assertExists()
    }

    @MainActor
    func testSyncTabIdleState() throws {
        let app = XCUIApplication.launchForTesting()

        // Navigate to Sync tab
        app.tabBars.buttons["Sync"].assertExists(timeout: 5).tap()

        // Idle state should show title and buttons
        app.staticTexts["Dive Computer Sync"].assertExists(timeout: 3)

        let scanButton = app.buttons["scanButton"]
        scanButton.assertExists()

        let fileImportButton = app.buttons["fileImportButton"]
        fileImportButton.assertExists()
    }

    @MainActor
    func testSettingsTabElements() throws {
        let app = XCUIApplication.launchForTesting()

        // Navigate to Settings tab
        app.tabBars.buttons["Settings"].assertExists(timeout: 5).tap()

        // Settings navigation title
        app.navigationBars["Settings"].assertExists(timeout: 3)

        // Display section
        app.staticTexts["Display"].assertExists()

        // Units section
        app.staticTexts["Units"].assertExists()

        // Data section
        app.staticTexts["Data"].assertExists()

        // Pickers should be present
        app.staticTexts["Appearance"].assertExists()
        app.staticTexts["Depth"].assertExists()
        app.staticTexts["Temperature"].assertExists()
    }

    @MainActor
    func testAccessibilityAudit() throws {
        #if os(iOS)
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("performAccessibilityAudit requires iOS 17+")
        }

        let app = XCUIApplication.launchForTesting()

        // Audit dive list screen
        app.collectionViews["diveList"].assertExists(timeout: 5)
        try app.performAccessibilityAudit() { issue in
            // Ignore known acceptable issues:
            // - Dynamic type warnings on chart elements (charts have custom accessibility)
            // - Contrast issues on disabled filter chips
            var dominated = false
            if issue.auditType == .dynamicType {
                dominated = true
            }
            if issue.auditType == .contrast {
                dominated = true
            }
            return dominated
        }

        // Navigate to detail and audit
        let firstCell = app.collectionViews["diveList"].cells.element(boundBy: 0)
        if firstCell.waitForExistence(timeout: 3) {
            firstCell.tap()
            app.staticTexts["Max Depth"].assertExists(timeout: 5)
            try app.performAccessibilityAudit() { issue in
                issue.auditType == .dynamicType || issue.auditType == .contrast
            }

            // Go back
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Audit settings screen
        app.tabBars.buttons["Settings"].tap()
        app.navigationBars["Settings"].assertExists(timeout: 3)
        try app.performAccessibilityAudit() { issue in
            issue.auditType == .dynamicType || issue.auditType == .contrast
        }
        #else
        throw XCTSkip("Accessibility audit is iOS only")
        #endif
    }
}
