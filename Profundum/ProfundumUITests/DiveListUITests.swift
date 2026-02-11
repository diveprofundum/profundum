import XCTest

final class DiveListUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tests

    @MainActor
    func testDiveListShowsPopulatedState() throws {
        let app = XCUIApplication.launchForTesting()

        // The list should be populated with sample dives
        let list = app.collectionViews["diveList"]
        list.assertExists(timeout: 5)

        // Verify at least one sample dive site name appears
        let blueHeron = app.staticTexts["Blue Heron Bridge"]
        let eagleRay = app.staticTexts["Eagle Ray Alley"]
        let ginnie = app.staticTexts["Ginnie Springs - Ballroom"]
        let andrea = app.staticTexts["Andrea Doria"]

        let hasSampleData = blueHeron.waitForExistence(timeout: 3)
            || eagleRay.exists
            || ginnie.exists
            || andrea.exists
        XCTAssertTrue(hasSampleData, "Expected at least one sample dive site to appear in the list")
    }

    @MainActor
    func testDiveListFilterChipsExist() throws {
        let app = XCUIApplication.launchForTesting()

        // Wait for list to load
        app.collectionViews["diveList"].assertExists(timeout: 5)

        // Filter bar should exist with type filter chips
        let filterBar = app.scrollViews["filterBar"]
        filterBar.assertExists()

        // DiveTypeFilter chips have accessibility labels "<Name> filter"
        let ccrChip = app.buttons["CCR filter"]
        let ocChip = app.buttons["OC filter"]
        ccrChip.assertExists()
        ocChip.assertExists()

        // Activity tag chips
        let recChip = app.buttons["Rec filter"]
        recChip.assertExists()
    }

    @MainActor
    func testDiveListFilterToggle() throws {
        let app = XCUIApplication.launchForTesting()

        // Wait for list to load
        app.collectionViews["diveList"].assertExists(timeout: 5)

        // Count initial cells
        let initialCellCount = app.collectionViews["diveList"].cells.count
        XCTAssertGreaterThan(initialCellCount, 0, "Expected sample dives in list")

        // Tap CCR filter chip
        let ccrChip = app.buttons["CCR filter"]
        ccrChip.assertExists()
        ccrChip.tap()

        // List should update — may have fewer items (only CCR dives)
        sleep(1) // Allow filter to apply
        let filteredCount = app.collectionViews["diveList"].cells.count
        XCTAssertGreaterThan(filteredCount, 0, "Expected at least one CCR dive")
        XCTAssertLessThanOrEqual(filteredCount, initialCellCount)

        // Clear button should appear — may be offscreen in the horizontal
        // filter ScrollView, so scroll it into view first
        let filterBar = app.scrollViews["filterBar"]
        let clearButton = filterBar.buttons["Clear"]
        clearButton.assertExists()
        filterBar.swipeLeft()
        // After swipe, the button should be hittable
        if !clearButton.isHittable {
            filterBar.swipeLeft()
        }
        clearButton.tap()

        // List should restore
        sleep(1)
        let restoredCount = app.collectionViews["diveList"].cells.count
        XCTAssertEqual(restoredCount, initialCellCount, "Expected list to restore after clearing filters")
    }

    @MainActor
    func testDiveListSearchField() throws {
        let app = XCUIApplication.launchForTesting()

        // Wait for list to load
        app.collectionViews["diveList"].assertExists(timeout: 5)

        // Tap into search field
        let searchField = app.searchFields.firstMatch
        searchField.assertExists()
        searchField.tap()
        searchField.typeText("Andrea")

        // Wait for debounce (300ms) + rendering
        sleep(1)

        // Andrea Doria dive should be visible
        let andrea = app.staticTexts["Andrea Doria"]
        andrea.assertExists(timeout: 3)
    }

    @MainActor
    func testDiveListAddDiveOpensSheet() throws {
        let app = XCUIApplication.launchForTesting()

        // Wait for list to load
        app.collectionViews["diveList"].assertExists(timeout: 5)

        // On iOS, the add button is inside the ellipsis menu
        let menuButton = app.navigationBars.buttons["More"].firstMatch
        if menuButton.waitForExistence(timeout: 2) {
            menuButton.tap()
            let addButton = app.buttons["Add Dive"]
            addButton.assertExists()
            addButton.tap()
        } else {
            // macOS: direct plus button in toolbar
            let plusButton = app.navigationBars.buttons.element(boundBy: 0)
            plusButton.tap()
        }

        // NewDiveSheet should appear with its title
        let sheetTitle = app.staticTexts["New Dive"]
        sheetTitle.assertExists(timeout: 3)

        // Cancel to dismiss
        let cancelButton = app.buttons["cancelButton"]
        cancelButton.assertExists()
        cancelButton.tap()
    }

    @MainActor
    func testDiveListSwipeToDelete() throws {
        #if os(iOS)
        let app = XCUIApplication.launchForTesting()

        // Wait for list to load
        let list = app.collectionViews["diveList"]
        list.assertExists(timeout: 5)

        let initialCount = list.cells.count
        XCTAssertGreaterThan(initialCount, 0, "Expected sample dives")

        // Swipe left on the first cell to reveal delete action
        let firstCell = list.cells.element(boundBy: 0)
        firstCell.swipeLeft()

        // Tap the Delete button
        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 2) {
            deleteButton.tap()

            // Wait for deletion animation
            sleep(1)

            let newCount = list.cells.count
            XCTAssertEqual(newCount, initialCount - 1, "Expected one fewer dive after deletion")
        }
        #else
        throw XCTSkip("Swipe-to-delete is iOS only")
        #endif
    }
}
