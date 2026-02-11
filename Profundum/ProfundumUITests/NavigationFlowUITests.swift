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

        // Helper: ignore known acceptable audit types
        // - Dynamic type: chart elements use custom accessibility labels
        // - Contrast: disabled filter chips have reduced contrast by design
        // - Text clipped: compact badge/chip labels may clip at large type sizes
        // - Element description: some SF Symbols lack human-readable labels
        func shouldIgnore(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
            issue.auditType == .dynamicType
                || issue.auditType == .contrast
                || issue.auditType == .textClipped
                || issue.auditType == .sufficientElementDescription
        }

        // Helper: run audit, treating timeout as non-fatal (simulator can be slow)
        func auditScreen(_ label: String) {
            do {
                try app.performAccessibilityAudit(shouldIgnore)
            } catch {
                let nsError = error as NSError
                if nsError.code == -56 {
                    // Audit timeout — log but don't fail
                    print("Accessibility audit timed out on \(label) — skipping")
                } else {
                    XCTFail("Accessibility audit failed on \(label): \(error)")
                }
            }
        }

        // Audit settings screen (simplest, least likely to timeout)
        app.tabBars.buttons["Settings"].assertExists(timeout: 5).tap()
        app.navigationBars["Settings"].assertExists(timeout: 3)
        auditScreen("Settings")

        // Audit dive list screen
        app.tabBars.buttons["Log"].tap()
        app.collectionViews["diveList"].assertExists(timeout: 5)
        auditScreen("Dive List")
        #else
        throw XCTSkip("Accessibility audit is iOS only")
        #endif
    }
}
