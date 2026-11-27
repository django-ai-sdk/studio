import XCTest

/// Smoke test: open Workflows and a workflow on iPhone, saving a screenshot after each step.
/// Needs a signed-in session in the simulator (sign in once by hand) and the backend running.
final class NavigationUITests: XCTestCase {
    func testOpenWorkflow() throws {
        let app = XCUIApplication()
        app.launch()
        snap(app, "1-start")

        let workflows = app.staticTexts["Workflows"].firstMatch
        XCTAssertTrue(workflows.waitForExistence(timeout: 10), "Workflows row in sidebar")
        workflows.tap()
        sleep(2)
        snap(app, "2-workflows")

        let row = app.staticTexts["send-money-to-user"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "workflow row")
        row.tap()
        sleep(2)
        snap(app, "3-workflow")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let dir = ProcessInfo.processInfo.environment["UITEST_SHOTS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
