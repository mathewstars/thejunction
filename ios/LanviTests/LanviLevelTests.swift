import XCTest
@testable import Lanvi

/// The level maths: XP total -> level, XP into it, XP it needs.
final class LanviLevelTests: XCTestCase {

    func testStartsAtLevelOne() {
        XCTAssertEqual(LanviLevel(xp: 0), LanviLevel(level: 1, into: 0, needed: 30))
        XCTAssertEqual(LanviLevel(xp: -40), LanviLevel(level: 1, into: 0, needed: 30))
    }

    func testFirstLevelsTakeAboutThreeActivities() {
        XCTAssertEqual(LanviLevel(xp: 29).level, 1)
        XCTAssertEqual(LanviLevel(xp: 30), LanviLevel(level: 2, into: 0, needed: 35))
        XCTAssertEqual(LanviLevel(xp: 64).level, 2)
        XCTAssertEqual(LanviLevel(xp: 65), LanviLevel(level: 3, into: 0, needed: 40))
    }

    func testBoundaries() {
        // Level starts: 0, 30, 65, 105, 150, 200, 255, 315.
        XCTAssertEqual((1...8).map(LanviLevel.start(of:)), [0, 30, 65, 105, 150, 200, 255, 315])
        for n in 1...40 {
            let s = LanviLevel.start(of: n)
            XCTAssertEqual(LanviLevel(xp: s), LanviLevel(level: n, into: 0, needed: LanviLevel.needed(for: n)))
            if n > 1 { XCTAssertEqual(LanviLevel(xp: s - 1).level, n - 1) }
        }
    }

    func testTheDemoNumbers() {
        // -demoXP 230 (the demo's default) and 250 (-demoLevelUp: one activity crosses).
        XCTAssertEqual(LanviLevel(xp: 230), LanviLevel(level: 6, into: 30, needed: 55))
        XCTAssertEqual(LanviLevel(xp: 250).toNext, 5)
        XCTAssertEqual(LanviLevel(xp: 260).level, 7)
    }

    func testGrowsSlowlyAndCaps() {
        XCTAssertEqual(LanviLevel.needed(for: 2) - LanviLevel.needed(for: 1), 5)
        XCTAssertEqual(LanviLevel.needed(for: 15), 100)
        XCTAssertEqual(LanviLevel.needed(for: 500), 100)
    }

    func testAlwaysGoesUpAndProgressStaysInRange() {
        var last = LanviLevel(xp: 0)
        for xp in 0...6_000 {
            let l = LanviLevel(xp: xp)
            XCTAssertGreaterThanOrEqual(l.level, last.level)
            XCTAssertTrue((0..<1).contains(l.progress))
            XCTAssertEqual(l.into + l.toNext, l.needed)
            XCTAssertEqual(LanviLevel.start(of: l.level) + l.into, xp)
            last = l
        }
    }
}
