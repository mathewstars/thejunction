import XCTest

/// Walks every non-game path the way a person would, with human pauses, so a
/// screen recording of the run shows any glitch: first run (welcome, what helps,
/// the Health question), then Home (the fox, the bubble, the chat, more, growth,
/// Help, a game opened and closed straight away), then the real-world suggestion
/// and the done-for-today state.
///
/// Every step prints `UIEVENT <name> <unix time>` so frames around it can be
/// cut out of the recording.
final class LanviFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
    }

    private func event(_ name: String) {
        print(String(format: "UIEVENT %@ %.3f", name, Date().timeIntervalSince1970))
    }

    private func pause(_ s: Double = 1.4) { Thread.sleep(forTimeInterval: s) }

    /// Tap the first hittable element matching a label, if it is there.
    @discardableResult
    private func tap(_ q: XCUIElementQuery, _ label: String, _ name: String, wait: Double = 4) -> Bool {
        // Labels can be shown in capitals by the button style: match without case.
        let e = q.matching(NSPredicate(format: "label ==[c] %@ OR identifier == %@ OR label BEGINSWITH[c] %@",
                                       label, label, label + ",")).firstMatch
        guard e.waitForExistence(timeout: wait) else {
            event("missing:\(name)")
            return false
        }
        event(name)
        e.tap()
        return true
    }

    /// Close a sheet the way a person does: tap the dimmed scene above it.
    private func closeSheet(_ name: String) {
        event(name)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
    }

    /// The opening: hold a finger on the kit in the snow until he wakes.
    private func holdKit(_ name: String) {
        event(name)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70)).press(forDuration: 3.4)
        pause(5.5)          // he wakes: "…you stayed." then "I'm Lanvi."
    }

    private func launch(_ extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-offline", "-hour", "13"] + extra
        app.launch()
    }

    /// Prints the accessibility tree of the first screen (to find labels).
    func test0Tree() {
        launch(["-firstRun"])
        pause(3)
        print("TREE-BEGIN")
        print(app.debugDescription)
        print("TREE-END")
    }

    func test1FirstRunAndHome() {
        launch(["-firstRun"])
        pause(2.5)

        // Welcome
        holdKit("rescue.hold")
        pause(1.8)

        // What usually helps you?
        tap(app.buttons, "Quiet", "helps.quiet")
        pause(0.9)
        tap(app.buttons, "Moving", "helps.moving")
        pause(0.9)
        tap(app.buttons, "That's it", "helps.continue")
        pause(3.2)

        // The Health question
        tap(app.buttons, "Not now", "health.notnow", wait: 6)
        pause(2.0)

        // Home
        tap(app.descendants(matching: .any), "home.fox", "home.fox", wait: 6)   // the puppet reacts; nothing opens
        pause(1.6)
        tap(app.buttons, "home.day", "home.day.growth")
        pause(1.8)
        closeSheet("growth.close")
        pause(1.5)

        tap(app.buttons, "home.speech", "home.bubble")
        pause(1.8)
        let field = app.textFields.matching(NSPredicate(format: "label == %@ OR placeholderValue == %@", "Write to Lanvi", "Write to Lanvi")).firstMatch
        if field.waitForExistence(timeout: 4) {
            event("chat.field")
            field.tap()
            pause(1.0)
            field.typeText("The coffee outside was nice")
            pause(0.6)
            tap(app.buttons, "chat.send", "chat.send")
            pause(3.0)
        }
        tap(app.buttons, "Close", "chat.close")
        pause(1.8)

        tap(app.buttons, "Talk to Lanvi", "home.chatbutton")
        pause(1.6)
        tap(app.buttons, "Close", "chat.close2")
        pause(1.6)

        tap(app.buttons, "More with Lanvi", "home.more")
        pause(1.6)
        closeSheet("more.close")
        pause(1.5)

        tap(app.buttons, "home.day", "home.day")
        pause(1.6)
        closeSheet("day.close")
        pause(1.5)

        tap(app.buttons, "Help", "home.help")
        pause(1.8)
        tap(app.buttons, "Close", "help.close")
        pause(1.8)

        // A game, opened and closed straight away (the face question comes first).
        tap(app.buttons, "home.primary", "home.primary")
        pause(1.6)
        tap(app.buttons, "Not now", "face.notnow", wait: 3)
        pause(1.4)
        tap(app.buttons, "Close", "game.close", wait: 3)
        pause(2.0)
    }

    /// The whole first run and a short tour of Home at a natural pace (about 40 s),
    /// for the flow recording.
    func test3Flow() {
        launch(["-firstRun"])
        pause(2.2)
        holdKit("flow.rescue")
        pause(1.8)
        tap(app.buttons, "Quiet", "flow.quiet")
        pause(0.8)
        tap(app.buttons, "Moving", "flow.moving")
        pause(1.0)
        tap(app.buttons, "That's it", "flow.continue")
        pause(3.0)
        tap(app.buttons, "Not now", "flow.health", wait: 6)
        pause(3.0)
        tap(app.buttons, "home.speech", "flow.bubble")
        pause(2.2)
        tap(app.buttons, "Close", "flow.chatclose")
        pause(1.8)
        tap(app.buttons, "More with Lanvi", "flow.more")
        pause(2.0)
        closeSheet("flow.moreclose")
        pause(1.6)
        tap(app.buttons, "home.day", "flow.growth")
        pause(2.2)
        closeSheet("flow.growthclose")
        pause(1.6)
        tap(app.buttons, "Help", "flow.help")
        pause(2.0)
        tap(app.buttons, "Close", "flow.helpclose")
        pause(2.5)
    }

    /// The chat keyboard can always be put away, and the buttons still work.
    /// Run with the on-screen keyboard on (simulator: ConnectHardwareKeyboard off).
    /// The captain: one quick tap anywhere outside the text box puts the keyboard
    /// away, and does nothing else (no scroll jump, no screen change).
    func test5ChatTapAnywhere() {
        launch(["-senseScreen", "none", "-screen", "home", "-demoOpen", "chat"])
        let field = app.textFields.matching(NSPredicate(format: "label == %@ OR placeholderValue == %@", "Write to Lanvi", "Write to Lanvi")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        let kb = app.keyboards.firstMatch
        let firstMessage = app.scrollViews.firstMatch.staticTexts.firstMatch
        XCTAssertTrue(firstMessage.waitForExistence(timeout: 4), "a message is on screen")
        for y in [0.15, 0.35, 0.55, 0.75] {
            field.tap()
            XCTAssertTrue(kb.waitForExistence(timeout: 3), "keyboard up before tap at \(y)")
            pause(0.8)
            let before = firstMessage.frame.minY
            // With the keyboard up, the screen below the text box is the keyboard
            // itself: the heights are taken within the visible chat, from the top
            // of the screen to just above the text box.
            let screenH = app.frame.height
            let visible = field.frame.minY - 14
            let point = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.width * 0.62, dy: visible * y))
            _ = screenH
            point.tap()
            let gone = NSPredicate(format: "exists == false")
            let ok = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: kb)], timeout: 1.5)
            XCTAssertEqual(ok, .completed, "one tap at \(Int(y * 100))% puts the keyboard away")
            pause(1.0)
            XCTAssertTrue(field.exists, "the chat is still open after a tap at \(Int(y * 100))%")
            let after = firstMessage.frame.minY
            XCTAssertEqual(after, before, accuracy: 2, "the chat did not scroll after a tap at \(Int(y * 100))%")
            event(String(format: "tap.%02d kb=%@ dy=%.1f", Int(y * 100), ok == .completed ? "gone" : "UP", after - before))
        }
    }

    /// The captain: a tap near the top of the chat opened the exercise. Taps on the
    /// chat stay in the chat, with the keyboard down too.
    func test6ChatTopTapsStayInChat() {
        launch(["-senseScreen", "none", "-screen", "home", "-demoOpen", "chat"])
        let field = app.textFields.matching(NSPredicate(format: "label == %@ OR placeholderValue == %@", "Write to Lanvi", "Write to Lanvi")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        pause(1.0)
        for y in [0.08, 0.15, 0.25, 0.40] {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: y)).tap()
            pause(1.2)
            XCTAssertTrue(field.exists, "the chat is still showing after a tap at \(Int(y * 100))%")
            XCTAssertFalse(app.buttons["Start"].exists, "no activity opened by a tap at \(Int(y * 100))%")
            event(String(format: "top.%02d chat=%@", Int(y * 100), field.exists ? "yes" : "GONE"))
        }
    }

    func test4ChatKeyboard() {
        launch(["-senseScreen", "none", "-screen", "home", "-demoOpen", "chat"])
        let field = app.textFields.matching(NSPredicate(format: "label == %@ OR placeholderValue == %@", "Write to Lanvi", "Write to Lanvi")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        let kb = app.keyboards.firstMatch
        func up() { field.tap(); XCTAssertTrue(kb.waitForExistence(timeout: 3), "keyboard up") }
        func gone(_ why: String) {
            let p = NSPredicate(format: "exists == false")
            expectation(for: p, evaluatedWith: kb)
            waitForExpectations(timeout: 3)
            event("kbd.gone.\(why)")
        }

        // 1. Tap on the list puts it away.
        up(); pause(0.6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        gone("tap-list")

        // 2. Tap on the scene at the top (beside Lanvi) puts it away.
        up(); pause(0.6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.17)).tap()
        gone("tap-scene")

        // 3. Dragging the list down puts it away.
        up(); pause(0.6)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        gone("drag")

        // 4. Return on an empty field puts it away.
        up(); pause(0.6)
        field.typeText("\n")
        gone("return-empty")

        // 5. Return with text sends and keeps it up.
        up(); pause(0.4)
        field.typeText("Hello Lanvi\n")
        pause(2.5)
        XCTAssertTrue(kb.exists, "keyboard stays up after sending")
        XCTAssertTrue(app.staticTexts["Hello Lanvi"].exists, "message sent with Return")
        event("kbd.return-sends")

        // 6. The send button works with the keyboard up.
        field.typeText("Second one")
        app.buttons["chat.send"].tap()
        pause(2.5)
        XCTAssertTrue(app.staticTexts["Second one"].exists, "send button works")
        XCTAssertTrue(kb.exists)
        event("kbd.send-button")

        // 7. X with the keyboard up closes the chat.
        app.buttons["Close"].tap()
        pause(1.5)
        XCTAssertFalse(field.exists, "chat closed with X")
        event("kbd.x-closes")
    }

    func test2RealWorldAndDone() {
        launch(["-senseScreen", "none", "-demoSuggestion", "walk_10min"])
        pause(3.0)
        tap(app.buttons, "I did it", "real.didit")
        pause(3.5)
        // Done for today keeps the whole row: More, Play again, the chat.
        XCTAssertTrue(app.buttons["home.primary"].waitForExistence(timeout: 3), "Play again is on Home when done")
        XCTAssertTrue(app.buttons["Talk to Lanvi"].exists, "the chat button is on Home when done")
        tap(app.buttons, "More with Lanvi", "done.more")
        pause(1.6)
        tap(app.buttons, "Sit with me a minute", "more.breathe")
        pause(1.8)
        tap(app.buttons, "Not now", "face.notnow2", wait: 2)
        pause(1.0)
        tap(app.buttons, "Close", "game.close2", wait: 3)
        pause(2.0)
    }
}
