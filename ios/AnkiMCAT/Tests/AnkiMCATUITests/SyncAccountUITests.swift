// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// UI proof for the sync feature: the app has an Account tab, and (signed out)
// it shows the branded sign-in card with username / password / server fields
// and a Sign In action. Drives the real UI via XCUITest and captures a
// screenshot of the sign-in screen.

import XCTest

final class SyncAccountUITests: XCTestCase {
    func testAccountTabShowsSignIn() throws {
        let app = XCUIApplication()
        app.launch()

        // The third tab exists alongside Review and Palace.
        let accountTab = app.tabBars.buttons["Account"]
        XCTAssertTrue(accountTab.waitForExistence(timeout: 30),
                      "Account tab should be present in the tab bar")
        accountTab.tap()

        // Branded, signed-out sign-in card.
        XCTAssertTrue(app.staticTexts["MCAT Sync"].waitForExistence(timeout: 5),
                      "Sign-in header should render")

        let signIn = app.buttons["Sign In"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5),
                      "Sign In button should render when signed out")

        // The credential fields are present.
        XCTAssertTrue(app.textFields["username"].exists, "username field present")
        XCTAssertTrue(app.secureTextFields["password"].exists, "password field present")

        // Sign In is disabled until credentials are entered (guards empty login).
        XCTAssertFalse(signIn.isEnabled,
                       "Sign In should be disabled with empty credentials")

        // Capture the product sign-in screen for visual review.
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "account-signin"
        att.lifetime = .keepAlways
        add(att)
    }
}
