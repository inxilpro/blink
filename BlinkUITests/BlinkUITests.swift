import XCTest

final class BlinkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Blink is a menu-bar agent: launching should leave it running in the
    /// background with no windows and no dock presence.
    @MainActor
    func testLaunchesAsBackgroundAgent() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertNotEqual(app.state, .notRunning)
        XCTAssertEqual(app.windows.count, 0)
    }
}
