import XCTest

extension XCUIApplication {
    /// Launch the app configured for UI testing with an in-memory database
    /// seeded with deterministic sample data.
    static func launchForTesting() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        return app
    }
}

extension XCUIElement {
    /// Assert this element exists within the given timeout, failing the test if not.
    @discardableResult
    func assertExists(
        timeout: TimeInterval = 5,
        _ message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let msg = message ?? "Expected element \(debugDescription) to exist"
        XCTAssertTrue(
            waitForExistence(timeout: timeout),
            msg,
            file: file,
            line: line
        )
        return self
    }

}
