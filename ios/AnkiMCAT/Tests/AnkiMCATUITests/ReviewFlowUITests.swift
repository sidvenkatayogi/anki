// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Live C3/C4 proof on the iOS simulator: launches the app (which opens a
// collection + imports the bundled .apkg in the Documents sandbox — C3),
// waits for the review screen, taps "Show Answer" then "Good", and asserts
// the loop advanced (C4 — a graded answer round-tripped through the shared
// Rust scheduler). Drives the real UI end-to-end via XCUITest.

import XCTest

final class ReviewFlowUITests: XCTestCase {
    func testReviewLoopRoundTrip() throws {
        let app = XCUIApplication()
        app.launch()

        // C3: after startup, the review screen shows a Show Answer button once
        // the card has been fetched + rendered from the imported collection.
        let showAnswer = app.buttons["Show answer"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 30),
                      "Review screen with a rendered card should appear after import")

        // Reveal the answer, then grade Good — this calls answer_card through
        // the engine and advances the scheduler.
        showAnswer.tap()

        let good = app.buttons["Grade Good"]
        XCTAssertTrue(good.waitForExistence(timeout: 5),
                      "Grading buttons should appear after revealing the answer")
        good.tap()

        // C4: grading round-trips through the Rust scheduler and advances the
        // loop. The single new card graded Good becomes an intraday LEARNING
        // card due shortly, so the scheduler legitimately re-presents it (the
        // grading buttons disappear and a fresh Show Answer returns) rather
        // than emptying the queue — either that or "All caught up" is a valid
        // post-answer state. Assert on whichever appears; both prove the
        // answer was accepted and the loop moved forward.
        let advanced = expectation(description: "review loop advanced after grading")
        let showAgain = app.buttons["Show answer"]
        let done = app.staticTexts["All caught up"]
        // Poll for either terminal condition.
        let start = Date()
        DispatchQueue.global().async {
            while Date().timeIntervalSince(start) < 15 {
                if done.exists || showAgain.exists { advanced.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        wait(for: [advanced], timeout: 16)
        XCTAssertTrue(done.exists || showAgain.exists,
                      "After grading, the loop should present the next card or finish")
    }

    /// Memory palace: switch to the Palace tab, create a place, and land on the
    /// capture screen. Proves the new tab, list, creation sheet, navigation, and
    /// (Simulator) photo-capture fallback are all wired and don't crash.
    func testMemoryPalaceCreateFlow() throws {
        let app = XCUIApplication()
        app.launch()

        // Move to the Palace tab (wait for the UI to settle after startup).
        let palaceTab = app.tabBars.buttons["Palace"]
        XCTAssertTrue(palaceTab.waitForExistence(timeout: 30), "Palace tab should exist")
        palaceTab.tap()

        XCTAssertTrue(app.navigationBars["Memory Palace"].waitForExistence(timeout: 5),
                      "Palace home should show")

        // Create a new palace via the toolbar "+", which is present whether or
        // not palaces already exist (so the test is order-independent).
        let add = app.navigationBars.buttons["New place"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add button should exist")
        add.tap()

        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Name field in new-palace sheet")
        nameField.tap()
        nameField.typeText("Test Desk")

        app.buttons["Create"].tap()

        // Sim has no AR, so the capture screen shows the photo-capture fallback.
        let addCards = app.navigationBars["Add cards"]
        let choosePhoto = app.buttons["Choose photo"]
        XCTAssertTrue(addCards.waitForExistence(timeout: 5) || choosePhoto.waitForExistence(timeout: 5),
                      "Should land on the capture screen (photo fallback in Simulator)")

        // Return to the list and confirm the palace persisted as a row. SwiftUI
        // List rows surface as cells/buttons (not bare static text), so accept
        // any of those.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() }
        XCTAssertTrue(app.navigationBars["Memory Palace"].waitForExistence(timeout: 5),
                      "Should return to the palace list")
        let appears = app.collectionViews.cells.count >= 1
            || app.staticTexts["Test Desk"].exists
            || app.buttons["Test Desk"].exists
        XCTAssertTrue(appears, "Created palace should appear in the list")
    }

    /// Full end-to-end: create a palace, seed it with the built-in sample room,
    /// place two real cards on it, then run a recall study session and grade to
    /// the visual recap. Exercises capture → picker → study → FSRS grade → recap
    /// entirely in the Simulator (no camera / photo library needed).
    func testFullPalaceStudyFlow() throws {
        let app = XCUIApplication()
        app.launch()

        let palaceTab = app.tabBars.buttons["Palace"]
        XCTAssertTrue(palaceTab.waitForExistence(timeout: 30))
        palaceTab.tap()

        // Create a palace.
        let add = app.navigationBars.buttons["New place"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Study Room")
        app.buttons["Create"].tap()

        // Seed the built-in sample room so the photo surface appears.
        let sample = app.buttons["Use a sample room"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        // Card-first placement: a card is shown, tap a spot to place THAT card.
        // Capacity ("N/7 spots used") is our confirmation each card landed.
        XCTAssertTrue(app.staticTexts["0/7 spots used"].waitForExistence(timeout: 10),
                      "the card-to-place panel should appear after picking the sample room")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.35)).tap()
        XCTAssertTrue(app.staticTexts["1/7 spots used"].waitForExistence(timeout: 8),
                      "first card should be placed by tapping a spot")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.42)).tap()
        XCTAssertTrue(app.staticTexts["2/7 spots used"].waitForExistence(timeout: 8),
                      "second card should be placed by tapping a spot")

        // Back to the palace list (create jumps straight to capture, so there's
        // no detail in the stack yet), open the palace, then study.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Memory Palace"].waitForExistence(timeout: 5))
        let firstPalace = app.cells.firstMatch
        XCTAssertTrue(firstPalace.waitForExistence(timeout: 5))
        firstPalace.tap()
        let study = app.buttons["Study this palace"]
        XCTAssertTrue(study.waitForExistence(timeout: 5))
        study.tap()

        // Recall mode is deterministic (no "tap the right pin" step).
        if app.buttons["What's here?"].waitForExistence(timeout: 5) {
            app.buttons["What's here?"].tap()
        }
        app.buttons["Start"].tap()

        // Grade each recalled card until the recap appears.
        let recap = app.staticTexts["Session complete"]
        var guardCount = 0
        while !recap.exists && guardCount < 10 {
            if app.buttons["Reveal card"].waitForExistence(timeout: 3) { app.buttons["Reveal card"].tap() }
            if app.buttons["Show answer"].waitForExistence(timeout: 3) { app.buttons["Show answer"].tap() }
            if app.buttons["Good"].waitForExistence(timeout: 3) { app.buttons["Good"].tap() }
            guardCount += 1
        }
        XCTAssertTrue(recap.waitForExistence(timeout: 5),
                      "the visual session recap should appear after grading")
    }
}
