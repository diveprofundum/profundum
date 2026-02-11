import XCTest

final class NewDiveSheetUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Helper: open the New Dive sheet from the dive list.
    @MainActor
    private func launchAndOpenNewDiveSheet() -> XCUIApplication {
        let app = XCUIApplication.launchForTesting()

        let list = app.collectionViews["diveList"]
        list.assertExists(timeout: 5)

        // On iOS the add button is inside the ellipsis menu
        let menuButton = app.navigationBars.buttons["More"].firstMatch
        if menuButton.waitForExistence(timeout: 2) {
            menuButton.tap()
            app.buttons["Add Dive"].assertExists().tap()
        } else {
            // macOS: direct toolbar button
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Wait for the sheet to appear
        app.staticTexts["New Dive"].assertExists(timeout: 3)

        return app
    }

    // MARK: - Tests

    @MainActor
    func testNewDiveSheetFormElements() throws {
        let app = launchAndOpenNewDiveSheet()

        // Basic Info section
        let basicInfo = app.staticTexts["Basic Info"]
        basicInfo.assertExists()

        // Site section
        let site = app.staticTexts["Site"]
        site.assertExists()

        // Depth & Time section
        let depthTime = app.staticTexts["Depth & Time"]
        depthTime.assertExists()

        // Dive Type section — may need scrolling on smaller screens
        // SwiftUI Form renders as a collectionView on iOS
        let form = app.collectionViews.firstMatch
        if !app.staticTexts["Dive Type"].waitForExistence(timeout: 2) {
            form.swipeUp()
        }
        app.staticTexts["Dive Type"].assertExists(timeout: 3)

        // Exposure section
        form.swipeUp()
        let exposure = app.staticTexts["Exposure"]
        exposure.assertExists(timeout: 3)

        // Tags section — further down
        form.swipeUp()
        let tags = app.staticTexts["Tags"]
        tags.assertExists(timeout: 3)
    }

    @MainActor
    func testNewDiveSheetSaveDisabledWithoutDevice() throws {
        let app = launchAndOpenNewDiveSheet()

        // Save button should exist but be disabled (no device selected)
        let saveButton = app.buttons["saveButton"]
        saveButton.assertExists()
        XCTAssertFalse(saveButton.isEnabled, "Save button should be disabled when no device is selected")
    }

    @MainActor
    func testNewDiveSheetDiveTypeToggles() throws {
        let app = launchAndOpenNewDiveSheet()

        // CCR toggle should exist
        let ccrToggle = app.switches["CCR Dive"]
        ccrToggle.assertExists()

        // Deco toggle should exist
        let decoToggle = app.switches["Deco Required"]
        decoToggle.assertExists()

        // Tap CCR toggle
        ccrToggle.tap()
        // The toggle should change value (no crash)

        // Tap Deco toggle
        decoToggle.tap()
    }

    @MainActor
    func testNewDiveSheetCancel() throws {
        let app = launchAndOpenNewDiveSheet()

        // Cancel should dismiss the sheet
        let cancelButton = app.buttons["cancelButton"]
        cancelButton.assertExists()
        cancelButton.tap()

        // Sheet title should no longer be visible
        let sheetTitle = app.staticTexts["New Dive"]
        XCTAssertFalse(
            sheetTitle.waitForExistence(timeout: 2),
            "New Dive sheet should be dismissed after cancel"
        )

        // We should be back on the dive list
        app.collectionViews["diveList"].assertExists()
    }
}
