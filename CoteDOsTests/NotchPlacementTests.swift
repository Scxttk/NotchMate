import AppKit
import XCTest
@testable import CoteDOs

/// The island is always docked to a screen border: dragged freely, landed on
/// the nearest one. These cover the pure geometry behind that — the panel's
/// frame per border, where the island sits inside it (the AppKit mirror of
/// `NotchRootView`'s alignment, so the cursor rects can't drift from what is
/// drawn), and which border a released drag picks.
final class NotchPlacementTests: XCTestCase {

    /// A 1440×900 display with its origin at zero, so expected values read as
    /// plain arithmetic.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let panelSize = CGSize(width: 520, height: 240)
    private let islandSize = CGSize(width: 50, height: 24)
    private let gap: CGFloat = 2
    private let centreSnap: CGFloat = 14
    private let cornerSnap: CGFloat = 48

    // MARK: Panel frame

    func testHomePanelHangsFromTheTopCentre() {
        let frame = NotchPlacement.home.panelFrame(screen: screen, panelSize: panelSize)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.maxY, screen.maxY)
    }

    func testAlongSlidesTheHorizontalDockSideways() {
        let placed = NotchPlacement(dock: .top, along: 300)
        let frame = placed.panelFrame(screen: screen, panelSize: panelSize)
        XCTAssertEqual(frame.midX, screen.midX + 300)
        XCTAssertEqual(frame.maxY, screen.maxY, "sliding along the top edge must not leave it")
    }

    func testBottomDockSitsOnTheBottomEdge() {
        let frame = NotchPlacement(dock: .bottom).panelFrame(screen: screen, panelSize: panelSize)
        XCTAssertEqual(frame.minY, screen.minY)
        XCTAssertEqual(frame.midX, screen.midX)
    }

    func testSideDocksHugTheirEdgeAndAlongRunsDownwards() {
        let leading = NotchPlacement(dock: .leading, along: 100).panelFrame(screen: screen, panelSize: panelSize)
        XCTAssertEqual(leading.minX, screen.minX)
        XCTAssertEqual(leading.midY, screen.midY - 100, "positive `along` is downward on a side edge")

        let trailing = NotchPlacement(dock: .trailing).panelFrame(screen: screen, panelSize: panelSize)
        XCTAssertEqual(trailing.maxX, screen.maxX)
        XCTAssertEqual(trailing.midY, screen.midY)
    }

    func testDodgeShiftsThePanelRightAndDown() {
        let frame = NotchPlacement.home.panelFrame(screen: screen, panelSize: panelSize,
                                                   dodge: CGSize(width: 200, height: 30))
        XCTAssertEqual(frame.midX, screen.midX + 200)
        XCTAssertEqual(frame.maxY, screen.maxY - 30)
    }

    // MARK: Island inside the panel

    func testIslandIsPinnedToTheDockedEdgeOfThePanel() {
        let panel = CGRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)

        let top = NotchPlacement(dock: .top).islandRect(inPanel: panel, size: islandSize, gap: gap)
        XCTAssertEqual(top.maxY, panel.maxY - gap)
        XCTAssertEqual(top.midX, panel.midX)

        let bottom = NotchPlacement(dock: .bottom).islandRect(inPanel: panel, size: islandSize, gap: gap)
        XCTAssertEqual(bottom.minY, panel.minY + gap)
        XCTAssertEqual(bottom.midX, panel.midX)

        let leading = NotchPlacement(dock: .leading).islandRect(inPanel: panel, size: islandSize, gap: gap)
        XCTAssertEqual(leading.minX, panel.minX + gap)
        XCTAssertEqual(leading.midY, panel.midY)

        let trailing = NotchPlacement(dock: .trailing).islandRect(inPanel: panel, size: islandSize, gap: gap)
        XCTAssertEqual(trailing.maxX, panel.maxX - gap)
        XCTAssertEqual(trailing.midY, panel.midY)
    }

    /// Expanding must grow the island *into* the screen. The panel never
    /// changes size, so this is the pinned edge holding still while the
    /// opposite one travels.
    func testExpandingGrowsInwardFromTheDockedEdge() {
        let panel = CGRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)
        let expanded = CGSize(width: 460, height: 212)

        for dock in NotchDock.allCases {
            let placement = NotchPlacement(dock: dock)
            let small = placement.islandRect(inPanel: panel, size: islandSize, gap: gap)
            let big = placement.islandRect(inPanel: panel, size: expanded, gap: gap)
            switch dock {
            case .top: XCTAssertEqual(small.maxY, big.maxY)
            case .bottom: XCTAssertEqual(small.minY, big.minY)
            case .leading: XCTAssertEqual(small.minX, big.minX)
            case .trailing: XCTAssertEqual(small.maxX, big.maxX)
            }
            XCTAssertTrue(panel.contains(big), "the expanded island must stay inside the panel on \(dock)")
        }
    }

    func testHeroShiftOnlyMovesTheIslandAlongAHorizontalEdge() {
        let panel = CGRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)
        let shifted = NotchPlacement.home.islandRect(inPanel: panel, size: islandSize, gap: gap, shift: 12)
        XCTAssertEqual(shifted.midX, panel.midX + 12)
        XCTAssertEqual(shifted.maxY, panel.maxY - gap)
    }

    // MARK: Landing

    func testADropNearTheBottomLandsOnTheBottomEdge() {
        // Island low and slightly right of centre: the bottom edge is 40 pt
        // away, every other one hundreds.
        let dropped = CGRect(x: 800, y: 40, width: islandSize.width, height: islandSize.height)
        let landed = NotchPlacement.snapping(islandRect: dropped, screen: screen,
                                             panelSize: { _ in self.panelSize }, centreSnap: centreSnap, cornerSnap: cornerSnap)
        XCTAssertEqual(landed.dock, .bottom)
        XCTAssertEqual(landed.along, dropped.midX - screen.midX)
    }

    func testADropNearTheLeftLandsOnTheLeadingEdge() {
        let dropped = CGRect(x: 12, y: 500, width: islandSize.width, height: islandSize.height)
        let landed = NotchPlacement.snapping(islandRect: dropped, screen: screen,
                                             panelSize: { _ in self.panelSize }, centreSnap: centreSnap, cornerSnap: cornerSnap)
        XCTAssertEqual(landed.dock, .leading)
        XCTAssertEqual(landed.along, screen.midY - dropped.midY)
    }

    func testADropNearTheRightLandsOnTheTrailingEdge() {
        let dropped = CGRect(x: screen.maxX - 60, y: 400, width: islandSize.width, height: islandSize.height)
        let landed = NotchPlacement.snapping(islandRect: dropped, screen: screen,
                                             panelSize: { _ in self.panelSize }, centreSnap: centreSnap, cornerSnap: cornerSnap)
        XCTAssertEqual(landed.dock, .trailing)
    }

    /// Released within a hair of an edge's centre, it lands exactly centred —
    /// on the top edge that is the home pose, which the Safari dodge, the
    /// menu-bar hide and the pill's hero centring all key off.
    func testALandingNearTheCentreSnapsHome() {
        let dropped = CGRect(x: screen.midX - islandSize.width / 2 + 9, y: screen.maxY - 26,
                             width: islandSize.width, height: islandSize.height)
        let landed = NotchPlacement.snapping(islandRect: dropped, screen: screen,
                                             panelSize: { _ in self.panelSize }, centreSnap: centreSnap, cornerSnap: cornerSnap)
        XCTAssertEqual(landed, .home)
        XCTAssertTrue(landed.isHome)
    }

    func testLandingKeepsThePanelOnScreen() {
        let dropped = CGRect(x: screen.maxX - 10, y: screen.maxY - 26,
                             width: islandSize.width, height: islandSize.height)
        let landed = NotchPlacement.snapping(islandRect: dropped, screen: screen,
                                             panelSize: { _ in self.panelSize }, centreSnap: centreSnap, cornerSnap: cornerSnap)
        let frame = landed.panelFrame(screen: screen, panelSize: panelSize)
        XCTAssertTrue(screen.contains(frame), "landed at \(frame) outside \(screen)")
    }

    func testClampGivesUpOnAScreenNarrowerThanThePanel() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 300)
        let along = NotchPlacement.clamped(along: 500, dock: .top, screen: tiny,
                                           panelSize: panelSize, centreSnap: centreSnap)
        XCTAssertEqual(along, 0)
    }

    /// Landing on a side border turns the island, so it has to be clamped
    /// inside the *portrait* panel it is about to become — clamping against
    /// the landscape one it was dragged as leaves it hanging off the screen.
    func testLandingOnASideUsesThatBordersOwnPanelSize() {
        let portrait = CGSize(width: 324, height: 480)
        let dropped = CGRect(x: 4, y: screen.maxY - 300, width: islandSize.width, height: islandSize.height)
        let landed = NotchPlacement.snapping(
            islandRect: dropped, screen: screen,
            panelSize: { $0.isHorizontal ? self.panelSize : portrait },
            centreSnap: centreSnap, cornerSnap: cornerSnap)
        XCTAssertEqual(landed.dock, .leading)
        let frame = landed.panelFrame(screen: screen, panelSize: portrait)
        XCTAssertTrue(screen.contains(frame), "landed at \(frame) outside \(screen)")
    }

    // MARK: Corners

    func testADropIntoACornerAnchorsThere() {
        let topLeft = CGRect(x: 6, y: screen.maxY - 26, width: islandSize.width, height: islandSize.height)
        let landed = NotchPlacement.snapping(islandRect: topLeft, screen: screen,
                                             panelSize: { _ in self.panelSize },
                                             centreSnap: centreSnap, cornerSnap: cornerSnap)
        XCTAssertEqual(landed.dock, .top)
        XCTAssertEqual(landed.anchor, .start)
        XCTAssertTrue(landed.anchor.isCorner)

        let bottomRight = CGRect(x: screen.maxX - 56, y: 4, width: islandSize.width, height: islandSize.height)
        let other = NotchPlacement.snapping(islandRect: bottomRight, screen: screen,
                                            panelSize: { _ in self.panelSize },
                                            centreSnap: centreSnap, cornerSnap: cornerSnap)
        XCTAssertEqual(other.dock, .bottom)
        XCTAssertEqual(other.anchor, .end)
    }

    /// The point of the anchor: a corner has to put the *island* in the corner,
    /// and the island is much shorter than the panel it lives in. Centred, a
    /// collapsed pill would sit a third of a screen away from the corner
    /// however far the panel went.
    func testACorneredIslandActuallyReachesTheCorner() {
        for (anchor, dock) in [(NotchPlacement.Anchor.start, NotchDock.top),
                               (.end, .top), (.start, .leading), (.end, .trailing)] {
            let placement = NotchPlacement(dock: dock, anchor: anchor)
            let panel = placement.panelFrame(screen: screen, panelSize: panelSize)
            let island = placement.islandRect(inPanel: panel, size: islandSize, gap: gap)
            let distance: CGFloat = dock.isHorizontal
                ? (anchor == .start ? island.minX - screen.minX : screen.maxX - island.maxX)
                : (anchor == .start ? screen.maxY - island.maxY : island.minY - screen.minY)
            XCTAssertEqual(distance, gap, accuracy: 0.001,
                           "\(dock)/\(anchor) left the island \(distance) pt from its corner")
        }
    }

    /// The centred placement is unaffected by the corner machinery — it is
    /// still the panel, centred, with the margin inside the screen.
    func testACentredIslandKeepsThePanelOnScreen() {
        let frame = NotchPlacement.home.panelFrame(screen: screen, panelSize: panelSize)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertTrue(screen.contains(frame))
    }

    func testAnchorSurvivesAsAStoredString() {
        for anchor in NotchPlacement.Anchor.allCases {
            XCTAssertEqual(NotchPlacement.Anchor(rawValue: anchor.rawValue), anchor)
        }
    }

    // MARK: Mirrored layout

    func testTheTabBandHugsWhicheverBorderTheIslandIsOn() {
        XCTAssertTrue(NotchDock.top.bandLeads)
        XCTAssertTrue(NotchDock.leading.bandLeads)
        XCTAssertFalse(NotchDock.bottom.bandLeads, "a pill on the bottom edge hands over downward")
        XCTAssertFalse(NotchDock.trailing.bandLeads)
    }

    func testLengthAndThicknessRoundTripOnEveryBorder() {
        for dock in NotchDock.allCases {
            let size = dock.size(length: 400, thickness: 30)
            let read = dock.lengthAndThickness(of: size)
            XCTAssertEqual(read.length, 400, "\(dock)")
            XCTAssertEqual(read.thickness, 30, "\(dock)")
            XCTAssertEqual(dock.isHorizontal, size.width > size.height, "\(dock)")
        }
    }

    /// The open island turns with the border, and its page area has to turn
    /// with it — otherwise a portrait island lays its pages out landscape and
    /// they overflow the silhouette.
    func testTheOpenIslandAndItsPagesTurnWithTheBorder() {
        let landscape = NotchLayout.expandedSize(on: .top)
        let portrait = NotchLayout.expandedSize(on: .leading)
        XCTAssertGreaterThan(landscape.width, landscape.height)
        XCTAssertGreaterThan(portrait.height, portrait.width)
        XCTAssertEqual(NotchLayout.expandedSize(on: .bottom), landscape)
        XCTAssertEqual(NotchLayout.expandedSize(on: .trailing), portrait)

        for dock in NotchDock.allCases {
            let island = NotchLayout.expandedSize(on: dock)
            let page = NotchLayout.expandedPageSize(on: dock)
            XCTAssertLessThan(page.width, island.width, "\(dock)")
            XCTAssertLessThan(page.height, island.height, "\(dock)")
            XCTAssertGreaterThan(page.width, 0, "\(dock)")
            XCTAssertGreaterThan(page.height, 0, "\(dock)")
        }
    }

    /// A tab slot must stay inside the pill's own band across the border, or
    /// the capsule shaves the glyphs it is handing over to.
    func testATabSlotFitsInsideThePillsBand() {
        for dock in NotchDock.allCases {
            let slot = NotchLayout.tabItemSize(on: dock)
            let thickness = dock.lengthAndThickness(of: slot).thickness
            XCTAssertLessThanOrEqual(thickness, NotchLayout.collapsedHeight, "\(dock)")
        }
    }

    // MARK: Gestures

    /// The swipe that opens the island means the same thing physically on every
    /// border: pull it out of the edge it is glued to.
    func testTheOpeningSwipePullsAwayFromEachBorder() {
        XCTAssertGreaterThan(NotchDock.top.openingAmount(dx: 0, dy: 10), 0, "down opens a top island")
        XCTAssertGreaterThan(NotchDock.bottom.openingAmount(dx: 0, dy: -10), 0, "up opens a bottom island")
        XCTAssertGreaterThan(NotchDock.leading.openingAmount(dx: 10, dy: 0), 0, "right opens a left island")
        XCTAssertGreaterThan(NotchDock.trailing.openingAmount(dx: -10, dy: 0), 0, "left opens a right island")

        XCTAssertLessThan(NotchDock.top.openingAmount(dx: 0, dy: -10), 0)
        XCTAssertLessThan(NotchDock.bottom.openingAmount(dx: 0, dy: 10), 0)
    }

    /// Paging runs along the border — the direction the tab strip itself reads
    /// — and never fights the opening swipe for the same gesture.
    func testPagingRunsAlongTheBorderAndNeverClashesWithOpening() {
        XCTAssertEqual(NotchDock.top.pagingAmount(dx: 7, dy: 0), 7)
        XCTAssertEqual(NotchDock.leading.pagingAmount(dx: 0, dy: 7), 7)
        for dock in NotchDock.allCases {
            XCTAssertEqual(dock.pagingAmount(dx: 0, dy: 9) == 0, dock.isHorizontal, "\(dock)")
            XCTAssertEqual(abs(dock.openingAmount(dx: 5, dy: 0)) == 0, dock.isHorizontal, "\(dock)")
        }
    }

    // MARK: Hover bleed

    func testBleedGrowsOutwardPastTheDockedEdgeOnly() {
        let rect = CGRect(x: 100, y: 100, width: 50, height: 24)
        let top = NotchDock.top.bleeding(rect, by: 10)
        XCTAssertEqual(top.minY, rect.minY)
        XCTAssertEqual(top.maxY, rect.maxY + 10)

        let bottom = NotchDock.bottom.bleeding(rect, by: 10)
        XCTAssertEqual(bottom.minY, rect.minY - 10)
        XCTAssertEqual(bottom.maxY, rect.maxY)

        let leading = NotchDock.leading.bleeding(rect, by: 10)
        XCTAssertEqual(leading.minX, rect.minX - 10)
        XCTAssertEqual(leading.maxX, rect.maxX)

        let trailing = NotchDock.trailing.bleeding(rect, by: 10)
        XCTAssertEqual(trailing.minX, rect.minX)
        XCTAssertEqual(trailing.maxX, rect.maxX + 10)
    }
}
