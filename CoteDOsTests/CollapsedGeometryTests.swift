import AppKit
import XCTest
@testable import CoteDOs

/// Unit tests for the collapsed pill's width and horizontal-shift formulas —
/// the two must stay in lock-step with each other and with the `CollapsedView`
/// layout (all three read the same `NotchLayout` constants).
@MainActor
final class CollapsedGeometryTests: XCTestCase {

    private var viewModel: NotchViewModel!
    private var originalSpectrumOnly = false
    private var originalSpectrumWidth = 0.0

    override func setUp() {
        super.setUp()
        viewModel = NotchViewModel()
        // Pin the setting the width formula branches on, so the tests don't
        // depend on whatever the host app's defaults happen to be.
        originalSpectrumOnly = UserSettings.shared.pillSpectrumOnly
        originalSpectrumWidth = UserSettings.shared.pillSpectrumWidth
        UserSettings.shared.pillSpectrumOnly = false
    }

    override func tearDown() {
        UserSettings.shared.pillSpectrumOnly = originalSpectrumOnly
        UserSettings.shared.pillSpectrumWidth = originalSpectrumWidth
        super.tearDown()
    }

    private func timerSegmentWidth(_ text: String) -> CGFloat {
        NotchLayout.collapsedTimerIconWidth + NotchLayout.collapsedTimerInnerSpacing
            + CGFloat(text.count) * NotchLayout.collapsedTimerCharWidth
    }

    private let endPadding = 2 * (NotchLayout.collapsedContentPadding + NotchLayout.collapsedEndPadding)

    // MARK: Width

    func testIdleWidthIsGlyphPlusPadding() {
        XCTAssertEqual(
            viewModel.collapsedWidth(isPlaying: false, hasItems: false, timerText: nil),
            NotchLayout.collapsedGlyphWidth + endPadding
        )
    }

    func testTimerOnlyWidth() {
        let text = "12:34"
        XCTAssertEqual(
            viewModel.collapsedWidth(isPlaying: false, hasItems: false, timerText: text),
            timerSegmentWidth(text) + endPadding
        )
    }

    func testHeroPlusTimerPlusBadgeWidth() {
        let text = "9:59"
        let heroCore = NotchLayout.collapsedArtworkWidth + NotchLayout.collapsedItemSpacing + NotchLayout.collapsedWavesWidth
        let expected = heroCore
            + NotchLayout.collapsedItemSpacing + timerSegmentWidth(text)
            + NotchLayout.collapsedItemSpacing + NotchLayout.collapsedBadgeWidth
            + endPadding
        XCTAssertEqual(
            viewModel.collapsedWidth(isPlaying: true, hasItems: true, timerText: text),
            expected
        )
    }

    /// The slider's value is snapped to a whole number of bars, so the pill is
    /// exactly as wide as the run inside it — never a fractional bar wider,
    /// which would show up as a gap next to the timer segment.
    func testSpectrumOnlyPillIsExactlyAsWideAsItsBars() {
        UserSettings.shared.pillSpectrumOnly = true
        // Between 9 bars (30.8) and 10 bars (34.4), nearer the former.
        UserSettings.shared.pillSpectrumWidth = 32
        let text = "12:34"
        let run = NotchLayout.pillSpectrumWidth(forBarCount: 9)
        XCTAssertEqual(NotchLayout.pillSpectrumBarCount(forWidth: 32), 9)
        XCTAssertEqual(
            viewModel.collapsedWidth(isPlaying: true, hasItems: false, timerText: text),
            run + NotchLayout.collapsedItemSpacing + timerSegmentWidth(text) + endPadding
        )
    }

    /// The pill is the spectrum page scaled down, so every slider position has
    /// to keep the page's proportions: a bar is `waveBarAspectRatio` times
    /// taller than wide, gaps are `waveBarGapRatio` of a bar, and the field is
    /// never flatter than the page's own aspect. That last one is the property
    /// that was missing — a fixed 2.0 pt raster let the widest setting stretch
    /// to 5.4× wider than tall and cram 32 hairlines in, which is exactly why
    /// it read as a stripe next to the page.
    func testWideningKeepsThePagesProportions() {
        var previousRun: CGFloat = 0
        for barCount in NotchLayout.pillSpectrumBarRange {
            let width = Double(NotchLayout.pillSpectrumWidth(forBarCount: barCount))
            let wave = NotchLayout.pillSpectrumGeometry(forWidth: width)

            XCTAssertEqual(wave.barWidth, wave.waveHeight / NotchLayout.waveBarAspectRatio, accuracy: 0.001,
                           "bar thickness must follow the field height at \(width) pt")
            XCTAssertEqual(wave.spacing, wave.barWidth * NotchLayout.waveBarGapRatio, accuracy: 0.001,
                           "gaps must stay proportional to the bars at \(width) pt")
            // Exactly its bars and gaps — never a fractional bar of overhang,
            // which would show up as a gap beside the timer segment.
            XCTAssertEqual(wave.runWidth,
                           CGFloat(wave.barCount) * wave.barWidth + CGFloat(wave.barCount - 1) * wave.spacing,
                           accuracy: 0.001)
            XCTAssertLessThanOrEqual(wave.runWidth, CGFloat(width) + 0.001,
                                     "the run may be narrower than asked for, never wider")
            XCTAssertGreaterThanOrEqual(wave.runWidth, previousRun - 0.001, "widening must not shrink the run")
            XCTAssertLessThanOrEqual(wave.runWidth / wave.waveHeight,
                                     NotchLayout.pillSpectrumFieldAspect + 0.01,
                                     "the field must never be flatter than the spectrum page's")
            previousRun = wave.runWidth
        }
    }

    /// The default is Apple's own run, measured off a real Dynamic Island:
    /// 6 bars, 2.0 pt wide, 1.6 pt gaps, 20.0 pt end to end. The scaled-page
    /// rule has to reproduce that exactly at the narrow end — that is what
    /// `pillSpectrumWaveHeightRange`'s lower bound is chosen for — otherwise
    /// making the wide setting better would have quietly retuned the default.
    func testDefaultWidthIsApplesSixBarRun() {
        XCTAssertEqual(NotchLayout.pillSpectrumDefaultWidth, 20.0, accuracy: 0.001)
        let wave = NotchLayout.pillSpectrumGeometry(forWidth: NotchLayout.pillSpectrumDefaultWidth)
        XCTAssertEqual(wave.barCount, 6)
        XCTAssertEqual(wave.barWidth, NotchLayout.collapsedWaveBarWidth, accuracy: 0.001)
        XCTAssertEqual(wave.spacing, NotchLayout.collapsedWaveSpacing, accuracy: 0.001)
        XCTAssertEqual(wave.runWidth, 20.0, accuracy: 0.001)
    }

    /// The widest setting is the point of the whole change: it should land on
    /// the page's own reading — around 19 chunky bars in a field near the
    /// page's aspect — rather than 32 hairlines, and the pill grows to hold it.
    func testWidestSettingMatchesTheSpectrumPage() {
        let wave = NotchLayout.pillSpectrumGeometry(forWidth: NotchLayout.pillSpectrumMaxWidth)
        XCTAssertEqual(wave.barCount, 19, "the widest pill should read like the page's run")
        XCTAssertGreaterThan(wave.barWidth, 3, "its bars should be chunky, not hairlines")
        XCTAssertEqual(wave.runWidth / wave.waveHeight, NotchLayout.pillSpectrumFieldAspect, accuracy: 0.1)
        XCTAssertGreaterThan(wave.pillHeight, NotchLayout.collapsedHeight,
                             "a wave that tall needs a taller pill than the menu bar's")
    }

    // MARK: Tab bar fit

    /// An `HStack` neither wraps nor truncates — it overflows its centre, so a
    /// row too wide for the band capsule puts its outer tabs outside the island.
    /// The labelled row needed scaling to fit; the icon-only one has to fit
    /// outright, at every tab count.
    func testTabRowFitsInsideTheIslandAtEveryTabCount() {
        let available = NotchLayout.bandWidth - 2 * NotchLayout.expandedContentInset
        for count in 1...NotchViewModel.Tab.allCases.count {
            let row = CGFloat(count) * NotchLayout.tabItemWidth
                + CGFloat(count - 1) * NotchLayout.tabBarSpacing
            XCTAssertLessThanOrEqual(row, available, "\(count) tabs must fit inside the island")
        }
    }

    /// Real drawn sizes, because `tabIconSize` has been raised on the strength
    /// of how the *open* island looked and then quietly broken the pill, which
    /// has 24 pt and a pair of rounded ends to give. `.band` draws the whole row
    /// at that height too. Anything taller is shaved by the island's clip.
    func testEveryTabGlyphFitsThePillBand() {
        let config = NSImage.SymbolConfiguration(pointSize: NotchLayout.tabIconSize, weight: .medium)
        for tab in NotchViewModel.Tab.allCases {
            guard let glyph = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else {
                XCTFail("no symbol named \(tab.icon)")
                continue
            }
            let size = glyph.size
            XCTAssertLessThanOrEqual(size.height, NotchLayout.collapsedHeight - 2,
                                     "\(tab.icon) is too tall for the 24 pt band")
            XCTAssertLessThanOrEqual(size.width, NotchLayout.collapsedGlyphWidth,
                                     "\(tab.icon) is wider than the pill budgets for it")
        }
    }

    /// The idle pill is sized from `collapsedGlyphWidth`, so that estimate has to
    /// cover the glyph *and* the padding around it — otherwise the content
    /// overflows a capsule that is clipping it, and the glyph reads as shaved.
    func testIdlePillHoldsItsGlyphWithoutClipping() {
        let width = viewModel.collapsedWidth(isPlaying: false, hasItems: false, timerText: nil)
        XCTAssertGreaterThanOrEqual(
            width,
            NotchLayout.collapsedGlyphWidth + 2 * NotchLayout.collapsedContentPadding,
            "the idle pill must be at least its glyph plus the row's own padding")
    }

    /// The premise of the pill ⇄ tab-bar handover being a hard cut: the glyph is
    /// in the same place on both sides of it. The tab bar reserves exactly the
    /// pill's band and takes the open island's breathing room as padding outside
    /// that band — grow the band instead and the glyph re-centres lower, which
    /// is a visible jump on the last frame of every collapse.
    func testTabBarReservesExactlyThePillBand() {
        XCTAssertEqual(NotchLayout.tabItemHeight, NotchLayout.collapsedHeight,
                       "a tab item is the pill band, filled")
    }

    // MARK: Shift

    func testShiftIsZeroWithoutHero() {
        XCTAssertEqual(viewModel.collapsedTrailingShift(isPlaying: false, hasItems: false, timerText: nil), 0)
        XCTAssertEqual(viewModel.collapsedTrailingShift(isPlaying: false, hasItems: false, timerText: "12:34"), 0,
                       "timer-only pill stays symmetric")
        XCTAssertEqual(viewModel.collapsedTrailingShift(isPlaying: false, hasItems: true, timerText: nil), 0,
                       "badge-only pill stays symmetric")
    }

    func testShiftIsZeroForHeroAlone() {
        XCTAssertEqual(viewModel.collapsedTrailingShift(isPlaying: true, hasItems: false, timerText: nil), 0)
    }

    func testHeroPlusTimerShiftIsHalfTheTrailingSegment() {
        let text = "12:34"
        XCTAssertEqual(
            viewModel.collapsedTrailingShift(isPlaying: true, hasItems: false, timerText: text),
            (NotchLayout.collapsedItemSpacing + timerSegmentWidth(text)) / 2
        )
    }

    func testHeroPlusTimerPlusBadgeShift() {
        let text = "45:00"
        let trailing = NotchLayout.collapsedItemSpacing + timerSegmentWidth(text)
            + NotchLayout.collapsedItemSpacing + NotchLayout.collapsedBadgeWidth
        XCTAssertEqual(
            viewModel.collapsedTrailingShift(isPlaying: true, hasItems: true, timerText: text),
            trailing / 2
        )
    }

    /// The invariant behind the whole asymmetric-pill feature: with the shift
    /// applied, the hero core's centre sits exactly on screen centre. The hero
    /// core spans from the pill's leading edge (plus paddings) through the
    /// artwork + wave; everything after it is "trailing".
    func testHeroCoreCentreLandsOnScreenCentreWithShift() {
        let text = "12:34"
        for hasItems in [false, true] {
            let width = viewModel.collapsedWidth(isPlaying: true, hasItems: hasItems, timerText: text)
            let shift = viewModel.collapsedTrailingShift(isPlaying: true, hasItems: hasItems, timerText: text)
            // Frame centred at 0, then shifted: leading edge at shift − width/2.
            let leadingEdge = shift - width / 2
            let heroCore = NotchLayout.collapsedArtworkWidth + NotchLayout.collapsedItemSpacing + NotchLayout.collapsedWavesWidth
            let heroCentre = leadingEdge + endPadding / 2 + heroCore / 2
            XCTAssertEqual(heroCentre, 0, accuracy: 0.001,
                           "hasItems=\(hasItems): hero core centre must sit on screen centre")
        }
    }
}
