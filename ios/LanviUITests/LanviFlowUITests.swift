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
        let field = app.textFields["Write to Lanvi"].firstMatch
        if field.waitForExistence(timeout: 4) {
            event("chat.field")
            field.tap()
            pause(1.0)
            field.typeText("The coffee outside was nice")
            pause(0.6)
            tap(app.buttons, "Send", "chat.send")
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

    func test2RealWorldAndDone() {
        launch(["-senseScreen", "none", "-demoSuggestion", "walk_10min"])
        pause(3.0)
        tap(app.buttons, "I did it", "real.didit")
        pause(3.5)
        tap(app.buttons, "Do something more", "done.more")
        pause(1.6)
        tap(app.buttons, "Breathe with me", "more.breathe")
        pause(1.8)
        tap(app.buttons, "Not now", "face.notnow2", wait: 2)
        pause(1.0)
        tap(app.buttons, "Close", "game.close2", wait: 3)
        pause(2.0)
    }
}
