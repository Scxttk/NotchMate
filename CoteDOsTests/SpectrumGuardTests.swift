import XCTest
@testable import CoteDOs

/// The rules that end an armed takeover — and lock the Mac behind it. (Whether
/// the Mac is actually idle, and whether the tap hears anything, can only be
/// checked by hand; this is the decision those two answers feed.)
final class SpectrumGuardTests: XCTestCase {

    private let grace = SpectrumGuard.silenceGraceSeconds

    func testAHandStillOnTheMacDoesNotEndIt() {
        // ⌥⌘S is itself a keystroke: without the hands-off latch the takeover
        // would end — and lock the Mac — in the same half-second it arrived.
        XCTAssertNil(SpectrumGuard.endCause(handsOff: false, idle: 0,
                                            startedWithAudio: true, silentFor: nil))
        XCTAssertNil(SpectrumGuard.endCause(handsOff: false, idle: 60,
                                            startedWithAudio: true, silentFor: nil))
    }

    func testComingBackEndsIt() {
        XCTAssertEqual(SpectrumGuard.endCause(handsOff: true, idle: 0,
                                              startedWithAudio: true, silentFor: nil), .input)
    }

    func testStaleInputIsNotSomebodyComingBack() {
        // Anything older than the reset window is the same untouched Mac the
        // takeover was left on, seen one poll later.
        XCTAssertNil(SpectrumGuard.endCause(handsOff: true,
                                            idle: SpectrumGuard.inputResetSeconds,
                                            startedWithAudio: true, silentFor: nil))
    }

    func testSilenceOnlyCountsPastTheGracePeriod() {
        // A gap between two tracks is not the music being over.
        XCTAssertNil(SpectrumGuard.endCause(handsOff: true, idle: 300,
                                            startedWithAudio: true, silentFor: grace - 1))
        XCTAssertEqual(SpectrumGuard.endCause(handsOff: true, idle: 300,
                                              startedWithAudio: true, silentFor: grace), .silence)
    }

    func testATakeoverArmedInASilentRoomNeverEndsItself() {
        // ⌥⌘S with nothing playing is as wanted as one over Spotify — it must
        // not lock the Mac ninety seconds later on its own.
        for silent in [0, grace, grace * 10] {
            XCTAssertNil(SpectrumGuard.endCause(handsOff: true, idle: 300,
                                                startedWithAudio: false, silentFor: silent))
        }
    }

    func testSomebodyBeingThereOutranksTheMusicRunningOut() {
        // Both rules fire at once when you come back to a Mac that fell silent
        // while you were gone. What you find in the pill should say "Eingabe".
        XCTAssertEqual(SpectrumGuard.endCause(handsOff: true, idle: 0,
                                              startedWithAudio: true, silentFor: grace * 2), .input)
    }

    func testIdleSecondsReadsTheSystemClock() {
        // Not a fixed value — just that the read works and is sane. A negative
        // or absurd answer would mean the CGEventSource call changed shape.
        let idle = SpectrumGuard.idleSeconds()
        XCTAssertGreaterThanOrEqual(idle, 0)
        XCTAssertLessThan(idle, 60 * 60 * 24)
    }
}
