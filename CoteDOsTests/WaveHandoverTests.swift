import XCTest
import SwiftUI
@testable import CoteDOs

/// The single spectrum run's two poses inside the island.
///
/// There used to be two waves — an overlay while the island opened, and the
/// spectrum page's own once the pages mounted — with a handover between them.
/// A handover between two independently mounted views is only ever as invisible
/// as the two poses happen to match, and they didn't: `pageWaveCentreY` counted
/// the tab bar above the page area but not the `expandedRowSpacing` between
/// them, so the run jumped 8 pt the frame the page took over. The seam is gone
/// now (one view, moved by transform), but these assertions still guard the
/// geometry that decides where it moves *to*.
final class WaveHandoverTests: XCTestCase {

    /// Where the spectrum page's area is actually centred, derived from the view
    /// tree rather than from the constant under test: the island is a `VStack`
    /// of the tab bar (`currentCollapsedHeight`) and the pages, separated by
    /// `expandedRowSpacing`, and the run centres in the frame it is given.
    private var pageCentreFromViewTree: CGFloat {
        NotchLayout.currentCollapsedHeight
            + NotchLayout.expandedRowSpacing
            + NotchLayout.expandedPageSize.height / 2
    }

    func testThePagePoseIsCentredOnThePageArea() {
        XCTAssertEqual(NotchLayout.pageWaveCentreY, pageCentreFromViewTree, accuracy: 0.01,
                       "the wave's page pose must be the centre of the page area, or it "
                       + "settles off-centre from everything around it")
    }

    /// The pill pose sits in the collapsed band, which is the row the pill's own
    /// content occupies.
    func testThePillPoseIsCentredOnTheCollapsedBand() {
        XCTAssertEqual(NotchLayout.pillWaveCentreY, NotchLayout.currentCollapsedHeight / 2,
                       accuracy: 0.01)
    }

    /// The journey has to be a real one, or there is nothing to animate.
    func testTheTwoPosesAreActuallyApart() {
        XCTAssertGreaterThan(NotchLayout.pageWaveCentreY - NotchLayout.pillWaveCentreY, 20,
                             "the page pose sits well below the pill's")
        XCTAssertLessThan(NotchLayout.pillToPageWaveScale, 0.5,
                          "and the pill is less than half the size")
    }

    /// The run is drawn once, at page geometry, and *scaled* to make the pill —
    /// so one number has to carry both dimensions. It only can if the scaled
    /// page run really is the pill's run; otherwise the wave sits at the right
    /// height and the wrong width, and clips against the capsule.
    func testOneScaleCarriesBothDimensionsOfThePillPose() {
        let pill = NotchLayout.pillSpectrumGeometry(forWidth: UserSettings.shared.pillSpectrumWidth)
        let page = NotchLayout.spectrumPageWaveGeometry(barCount: pill.barCount)
        let scale = NotchLayout.pillToPageWaveScale

        XCTAssertGreaterThan(scale, 0)
        XCTAssertLessThan(scale, 1, "the pill must be the smaller end, or there is no morph")
        XCTAssertEqual(page.waveHeight * scale, pill.waveHeight, accuracy: 0.5,
                       "the scaled page run must be exactly the pill's height")
        // Looser: the page spreads its bars across the full page width while the
        // pill's run is an exact fit for its bar count, so the two runs differ by
        // up to the leftover of one pitch.
        XCTAssertEqual(page.runWidth * scale, pill.runWidth,
                       accuracy: pill.barWidth + pill.spacing,
                       "the scaled page run must land within a bar of the pill's width")
    }

    /// `morphScale` is not decoration: the travelling run is *always* built at
    /// page geometry (`NotchRootView.morphingWave`), and shrinking it is the only
    /// thing that makes it the pill's. So every branch of `WaveBarsView` has to
    /// honour it — the procedural fallback included.
    ///
    /// It did not. The scale sat inside the live-bands branch, so a run with no
    /// tap data behind it drew at full page size inside the collapsed capsule and
    /// was clipped by it. Not a corner case: waking the Mac while Spotify reports
    /// playback from another device (Connect) is exactly that state — a player
    /// says "playing", the tap has nothing, the wave falls back to its loop.
    ///
    /// Measured as a ratio of two renders rather than against an absolute width,
    /// so the bars' glow — which spills past the run and scales with it — cancels
    /// out instead of needing a fudge factor.
    @MainActor
    func testTheProceduralFallbackShrinksIntoThePillToo() throws {
        let pill = NotchLayout.pillSpectrumGeometry(forWidth: UserSettings.shared.pillSpectrumWidth)
        let page = NotchLayout.spectrumPageWaveGeometry(barCount: pill.barCount)
        let scale = NotchLayout.pillToPageWaveScale

        for (name, bands) in [("procedural", nil), ("live", Array(repeating: CGFloat(0.6), count: pill.barCount))] as [(String, [CGFloat]?)] {
            let full = try litWidth(of: page, bands: bands, morphScale: 1)
            let shrunk = try litWidth(of: page, bands: bands, morphScale: scale)

            XCTAssertGreaterThan(full, 0, "the \(name) run must draw something to measure")
            XCTAssertEqual(shrunk / full, scale, accuracy: 0.06,
                           "the \(name) run must shrink by exactly the pill⇄page scale; "
                           + "a branch that ignores morphScale draws the page's wave inside the pill")
        }
    }

    /// Width of the lit part of a rendered run, in points — the wave against the
    /// island's black, measured rather than assumed.
    @MainActor
    private func litWidth(of geometry: NotchLayout.PillSpectrumGeometry,
                          bands: [CGFloat]?,
                          morphScale: CGFloat) throws -> CGFloat {
        // `isActive: false` freezes the procedural branch's timeline at its
        // resting frame, so the measurement doesn't depend on when it ran.
        let wave = WaveBarsView(
            isActive: false,
            tint: .white,
            bands: bands,
            count: geometry.barCount,
            maxHeight: geometry.waveHeight,
            barWidth: geometry.barWidth,
            spacing: geometry.spacing,
            morphScale: morphScale
        )
        .frame(width: geometry.runWidth, height: geometry.frameHeight)
        .background(Color.black)

        let renderer = ImageRenderer(content: wave)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "the run failed to render")
        let rep = NSBitmapImageRep(cgImage: image)

        var minX = image.width, maxX = -1
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in 0..<image.width where minX > x || maxX < x {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // Anything above the black background counts as bar or glow.
                guard color.brightnessComponent > 0.06 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard maxX >= minX else { return 0 }
        return CGFloat(maxX - minX + 1) / renderer.scale
    }

    /// The run stands in for the spectrum page while the carousel slides, so it
    /// has to travel exactly as far as that page does — one page width per tab
    /// of separation, in the same direction.
    func testTheCarouselShiftIsOnePageWidthPerTab() {
        let tabs = NotchViewModel.Tab.allCases
        guard let spectrumIndex = tabs.firstIndex(of: .spectrum),
              let musicIndex = tabs.firstIndex(of: .music) else {
            return XCTFail("the spectrum and music tabs must exist")
        }
        // Music sits before spectrum, so selecting it slides the spectrum page
        // to the right by exactly one page.
        XCTAssertEqual(spectrumIndex - musicIndex, 1)
        XCTAssertGreaterThan(NotchLayout.expandedPageSize.width, 0)
    }

    /// The spectrum page is the one tab meant to be left running, so the cursor
    /// leaving must not close it — and unlike the capture lock it has to release
    /// itself, or the island would be stuck open forever.
    @MainActor
    func testTheSpectrumPageHoldsTheIslandOpenAndReleasesItself() {
        let viewModel = NotchViewModel()

        viewModel.islandState = .expanded
        viewModel.selectedTab = .spectrum
        XCTAssertTrue(viewModel.holdsIslandOpen)

        viewModel.selectedTab = .music
        XCTAssertFalse(viewModel.holdsIslandOpen, "switching tabs must release the hold")

        viewModel.selectedTab = .spectrum
        viewModel.islandState = .collapsed
        XCTAssertFalse(viewModel.holdsIslandOpen, "closing the island must release the hold")
    }
}
