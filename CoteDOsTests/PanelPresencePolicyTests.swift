import XCTest
@testable import CoteDOs

/// Exhaustive matrix over the presence policy's inputs. The one invariant that
/// matters most: a hidden panel is *unconditionally* click-through — no cursor
/// position and no hotkey override may ever make an invisible panel grab
/// clicks (that is the focus-steal class of bug).
final class PanelPresencePolicyTests: XCTestCase {

    private let allHideSets: [Set<PanelPresencePolicy.HideReason>] = [
        [], [.idle], [.menuBarOverlap], [.userDisabled],
        [.idle, .menuBarOverlap], [.idle, .userDisabled], [.menuBarOverlap, .userDisabled],
        [.idle, .menuBarOverlap, .userDisabled],
    ]
    private let allPassiveSets: [Set<PanelPresencePolicy.PassiveReason>] = [
        [], [.safariFullscreen],
    ]

    func testHiddenIsAlwaysClickThrough() {
        for hide in allHideSets where !hide.isEmpty {
            for passive in allPassiveSets {
                let policy = PanelPresencePolicy(hideReasons: hide, passiveReasons: passive)
                XCTAssertTrue(policy.isHidden)
                for cursorInside in [false, true] {
                    for hotkey in [false, true] {
                        XCTAssertTrue(
                            policy.ignoresMouseEvents(cursorInsideInteractiveRect: cursorInside, hotkeyOverride: hotkey),
                            "hidden panel must ignore mouse events (hide: \(hide), passive: \(passive), cursorInside: \(cursorInside), hotkey: \(hotkey))"
                        )
                    }
                }
            }
        }
    }

    func testVisibleActiveFollowsCursor() {
        let policy = PanelPresencePolicy()
        XCTAssertFalse(policy.isHidden)
        XCTAssertTrue(policy.ignoresMouseEvents(cursorInsideInteractiveRect: false, hotkeyOverride: false))
        XCTAssertFalse(policy.ignoresMouseEvents(cursorInsideInteractiveRect: true, hotkeyOverride: false))
    }

    func testHotkeyOverrideForcesInteractiveWhenVisible() {
        let active = PanelPresencePolicy()
        XCTAssertFalse(active.ignoresMouseEvents(cursorInsideInteractiveRect: false, hotkeyOverride: true))

        let passive = PanelPresencePolicy(passiveReasons: [.safariFullscreen])
        XCTAssertFalse(passive.ignoresMouseEvents(cursorInsideInteractiveRect: false, hotkeyOverride: true))
    }

    func testPassiveIsClickThroughRegardlessOfCursor() {
        let policy = PanelPresencePolicy(passiveReasons: [.safariFullscreen])
        XCTAssertFalse(policy.isHidden, "passive keeps the panel visible")
        XCTAssertTrue(policy.ignoresMouseEvents(cursorInsideInteractiveRect: true, hotkeyOverride: false))
        XCTAssertTrue(policy.ignoresMouseEvents(cursorInsideInteractiveRect: false, hotkeyOverride: false))
    }

    func testRemovingOneHideReasonKeepsTheOther() {
        var policy = PanelPresencePolicy(hideReasons: [.idle, .menuBarOverlap])
        policy.hideReasons.remove(.menuBarOverlap)
        XCTAssertTrue(policy.isHidden, "lifting the overlap must not un-hide an idle panel")
        policy.hideReasons.remove(.idle)
        XCTAssertFalse(policy.isHidden)
    }

    func testUserPauseSurvivesTheIdleCycle() {
        // While paused, the idle logic keeps inserting/removing `.idle` as
        // music starts and stops — none of that may resurrect the panel.
        var policy = PanelPresencePolicy(hideReasons: [.userDisabled])
        policy.hideReasons.insert(.idle)
        policy.hideReasons.remove(.idle)
        XCTAssertTrue(policy.isHidden, "the user's pause must outlive any idle transition")
        XCTAssertTrue(policy.ignoresMouseEvents(cursorInsideInteractiveRect: true, hotkeyOverride: true),
                      "a paused panel never takes clicks, even hovered and hotkeyed")
    }
}
