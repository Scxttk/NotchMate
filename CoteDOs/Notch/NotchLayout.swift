import SwiftUI

/// Central source of truth for the island's geometry, animation and timing
/// constants. Every magic number belongs here rather than inline in
/// `NotchViewModel`, `NotchWindowController`, `IslandShape` or the views — most
/// of them are tuned against each other, and a value that lives next to its one
/// call site gets retuned without the others.
///
/// Put new ones here too.
enum NotchLayout {

    // MARK: Visible island dimensions

    /// Height of the collapsed pill — matches the macOS menu bar (24pt), so the
    /// pill reads as part of the bar. The expanded tab bar reuses this band
    /// (flush top, same height) so glyphs share the same y in both states.
    static let collapsedHeight: CGFloat = 24

    // MARK: Collapsed content metrics
    // The collapsed pill hugs whatever it shows, so its width is computed from
    // these element widths (see `NotchViewModel.collapsedWidth`). They must match
    // the `CollapsedView` layout. Getting this wrong shows up as clipped content,
    // because the island is clipped to the notch silhouette.

    /// The lone tab glyph shown when nothing is playing. Measured, not guessed:
    /// at `tabIconSize` the widest of the five (`radio.fill`, `tray.full`) draws
    /// 22pt across. It used to say 14, which left the glyph overflowing its own
    /// pill — and since the pill is clipped to a capsule, the overflow was eaten
    /// by the rounded ends and the glyph read as shaved down its sides.
    static let collapsedGlyphWidth: CGFloat = 22
    /// Now-playing artwork thumbnail. Sized so it keeps ~5pt of black above it
    /// in the 24pt pill — at 16pt it read as pressed against the top screen
    /// edge.
    static let collapsedArtworkWidth: CGFloat = 14
    /// The little frequency (wave-bars) visualizer next to the artwork.
    /// 5 × 2.0 + 4 × 1.6 = 16.4, rounded up for a hair of buffer.
    static let collapsedWavesWidth: CGFloat = 17
    /// Corner radius of the collapsed pill's artwork thumbnail.
    static let collapsedArtworkCornerRadius: CGFloat = 3.5
    /// Wave-bars geometry inside the collapsed pill. Both numbers are measured
    /// off a real iPhone's Dynamic Island rather than guessed: screenshots of
    /// the now-playing island (3× scale, converted to points) give bars of
    /// 1.67–2.33 pt with 1.33–2.00 pt of air between them, on a 3.67 pt pitch.
    /// Ours were 2.0 wide with only 1.0 of gap, which reads as a denser, more
    /// clotted run than Apple's.
    static let collapsedWaveBarCount: Int = 5
    static let collapsedWaveMaxHeight: CGFloat = 12
    static let collapsedWaveBarWidth: CGFloat = 2.0
    static let collapsedWaveSpacing: CGFloat = 1.6
    // MARK: Spectrum-only pill

    /// Spectrum-only pill (`UserSettings.pillSpectrumOnly`): the wave replaces
    /// the artwork thumbnail entirely and the whole pill grows into a stage
    /// for it — this mode exists to *watch*, so it deliberately takes more
    /// room than the cover+wave layout it replaces.
    ///
    /// There is exactly **one** knob, `UserSettings.pillSpectrumWidth`, and it
    /// widens the wave. Bar width and gap never change with it; the run simply
    /// gains bars, and the pill grows to hold them. Letting the user set width
    /// *and* bar count independently (as this did) meant every combination
    /// re-spaced the bars, so most settings looked wrong and the defaults were
    /// the only ones tuned.
    ///
    /// Centre-to-centre distance between two bars.
    static var pillSpectrumBarPitch: CGFloat { collapsedWaveBarWidth + collapsedWaveSpacing }

    /// Gap as a fraction of bar width (1.6 / 2.0). The one number that has to
    /// survive when the wave is scaled to a surface it was never sized for —
    /// the spectrum page, or a screen saver — so a blown-up run keeps the
    /// proportions measured off the Dynamic Island instead of turning into
    /// either hairlines or slabs.
    static var waveBarGapRatio: CGFloat { collapsedWaveSpacing / collapsedWaveBarWidth }

    /// Bar width that fits exactly `count` bars into `width` at that ratio.
    /// `width = count·b + (count-1)·ratio·b`, solved for `b`.
    static func waveBarWidth(fitting count: Int, into width: CGFloat) -> CGFloat {
        let n = CGFloat(max(1, count))
        return width / (n + (n - 1) * waveBarGapRatio)
    }
    /// Narrowest and widest the run may get, in bars.
    static let pillSpectrumBarRange = 4...32

    /// Exact width of a run of `count` bars at the Apple raster (2.0 pt bars,
    /// 1.6 pt gaps) — no trailing gap. This is the scale the *slider* is
    /// calibrated in (its default, minimum and maximum); the rendered run
    /// derives its own thickness from the field height, and the two agree
    /// exactly at the narrow end. See `pillSpectrumWaveHeightRange`.
    static func pillSpectrumWidth(forBarCount count: Int) -> CGFloat {
        let n = max(1, count)
        return CGFloat(n) * collapsedWaveBarWidth + CGFloat(n - 1) * collapsedWaveSpacing
    }

    /// How many bars a requested width holds. Delegates to
    /// `pillSpectrumGeometry(forWidth:)` so the count, the bar thickness and
    /// the pill's own height can never be derived from different rules.
    static func pillSpectrumBarCount(forWidth width: Double) -> Int {
        pillSpectrumGeometry(forWidth: width).barCount
    }

    /// The requested width snapped to a whole number of bars. The view and the
    /// width estimate in `NotchViewModel.collapsedWidth` both read this, so the
    /// pill is always exactly as wide as the run inside it.
    static func pillSpectrumSnappedWidth(_ requestedWidth: Double) -> CGFloat {
        pillSpectrumGeometry(forWidth: requestedWidth).runWidth
    }

    /// Apple's own run, measured: 6 bars, 20.0 pt end to end. That is the
    /// default the slider starts at.
    static var pillSpectrumDefaultWidth: Double { Double(pillSpectrumWidth(forBarCount: 6)) }
    static var pillSpectrumMinWidth: Double { Double(pillSpectrumWidth(forBarCount: pillSpectrumBarRange.lowerBound)) }
    static var pillSpectrumMaxWidth: Double { Double(pillSpectrumWidth(forBarCount: pillSpectrumBarRange.upperBound)) }

    // MARK: Spectrum-only pill proportions
    //
    // The spectrum-only pill is the spectrum *page* scaled down, not a
    // separate design. Side by side the page read far better than the pill at
    // the same settings, and the reason was measurable: the page's field is
    // ~2.8× wider than tall and holds ~19 chunky bars, while the pill's was
    // 5.4× wider than tall and crammed 32 hairlines into it. Same data, half
    // the vertical range per bar, twice the bar density.
    //
    // So both now follow one rule — a bar is `waveBarAspectRatio` times taller
    // than it is wide, gaps are `waveBarGapRatio` of a bar — and the pill
    // derives everything from the single width knob via
    // `pillSpectrumGeometry(forWidth:)`.

    /// A fully deflected bar is this many times taller than it is wide. Shared
    /// with `SpectrumStageView`, which is where the proportion was tuned.
    static let waveBarAspectRatio: CGFloat = 12
    /// How much wider than tall the pill's wave field sits, measured off the
    /// spectrum page (356 × 126 pt usable → 2.83). Keeping this ratio is what
    /// makes the pill read as the page in miniature rather than as a stripe.
    static let pillSpectrumFieldAspect: CGFloat = 2.83
    /// The same for a run standing on a side border.
    ///
    /// The letterbox exists so a squarish field doesn't produce a handful of
    /// enormous bars, and the landscape page never actually hits it — its own
    /// height binds first. A portrait page is far squarer (≈1.5), so 2.83 held
    /// the run to barely half the width it had and left the rest black. 1.9 is
    /// the loosest ratio at which the bars still read as bars: at the portrait
    /// page's ~290 pt run that is a 12 pt bar, against the landscape page's 11.
    static let portraitStageFieldAspect: CGFloat = 1.9
    /// Vertical range the wave may occupy. The lower bound is not arbitrary:
    /// 24 / `waveBarAspectRatio` is exactly `collapsedWaveBarWidth` (2.0 pt),
    /// so at the narrow end the derived geometry *is* the Apple-measured one —
    /// 6 bars, 2.0 pt wide, 1.6 pt gaps, a 20.0 pt run — and the default keeps
    /// the look that was measured off a real Dynamic Island. The upper bound
    /// stops the widest setting from growing a pill that swallows the menu bar.
    static let pillSpectrumWaveHeightRange: ClosedRange<CGFloat> = 24...42
    /// Black kept above and below the wave inside the pill — glow room, and
    /// what makes the run sit *in* a capsule rather than fill it.
    static let pillSpectrumWavePadding: CGFloat = 4.5

    /// Everything the spectrum-only pill needs, derived from the one knob so
    /// the view, the width estimate in `NotchViewModel.collapsedWidth` and the
    /// tests can never disagree about it.
    struct PillSpectrumGeometry: Equatable {
        /// Tallest a fully deflected bar gets.
        let waveHeight: CGFloat
        let barWidth: CGFloat
        let spacing: CGFloat
        let barCount: Int
        /// Exact width of the run — no trailing gap. The pill is this wide.
        let runWidth: CGFloat
        /// Frame the wave is given inside the pill (`waveHeight` + glow room).
        var frameHeight: CGFloat { waveHeight + pillSpectrumWavePadding }
        /// Height of the whole capsule in spectrum-only mode.
        var pillHeight: CGFloat { waveHeight + 2 * pillSpectrumWavePadding }
    }

    /// Scales the spectrum page down to a requested run width: the field keeps
    /// the page's aspect (so a wider pill is also a taller one), bar thickness
    /// follows the height, and the run then holds however many bars fit at
    /// that pitch — which is why widening gives *fewer, fatter* bars than the
    /// old fixed 2.0 pt raster did, and why it looks like the page.
    static func pillSpectrumGeometry(forWidth requestedWidth: Double) -> PillSpectrumGeometry {
        let width = CGFloat(max(0, requestedWidth))
        let waveHeight = min(pillSpectrumWaveHeightRange.upperBound,
                             max(pillSpectrumWaveHeightRange.lowerBound, width / pillSpectrumFieldAspect))
        let barWidth = waveHeight / waveBarAspectRatio
        let spacing = barWidth * waveBarGapRatio
        let pitch = barWidth + spacing
        // Floor, not round: a run may be narrower than asked for, never wider —
        // a fractional bar of overhang shows up as a gap beside the timer. The
        // epsilon keeps an exact fit (a width that *is* n bars) from falling to
        // n-1 on a floating-point hair.
        let fits = Int((width + spacing) / pitch + 1e-9)
        let barCount = min(max(fits, pillSpectrumBarRange.lowerBound), pillSpectrumBarRange.upperBound)
        let runWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        return PillSpectrumGeometry(waveHeight: waveHeight, barWidth: barWidth,
                                    spacing: spacing, barCount: barCount, runWidth: runWidth)
    }

    // MARK: Spectrum page proportions
    //
    // Lives here rather than inside `SpectrumStageView` because the pill needs
    // to *predict* it: closing the island shrinks the page's wave back into the
    // pill, and that animation needs its starting geometry before the page has
    // laid out (or after it has already gone).

    /// Never more than the analyzer actually resolves — past that the extra
    /// bars are interpolation, not information.
    static let stageMaximumBars = 32
    /// Breathing room so the tallest bar and its glow don't touch the edges.
    static let stageInset: CGFloat = 12

    /// The wave's geometry for a stage of `size` — bar thickness from the
    /// height (see `waveBarAspectRatio`), then as many bars as fit the width.
    /// The same rule the pill scales down, which is what lets the two morph.
    static func stageWaveGeometry(in size: CGSize, barCount forcedCount: Int? = nil,
                                  fieldAspect: CGFloat = pillSpectrumFieldAspect) -> PillSpectrumGeometry {
        let width = max(0, size.width - stageInset * 2)
        // Never taller than the page's own field shape. A whole screen is much
        // squarer than the panel (≈1.6 against 2.83), and since bar thickness
        // follows the field height, an unclamped fullscreen field produced a
        // handful of enormous bars instead of the page's run made bigger. Letter-
        // boxing keeps every size reading as the same wave.
        let height = min(max(0, size.height - stageInset * 2), width / fieldAspect)
        guard width > 0, height > 0 else {
            return PillSpectrumGeometry(waveHeight: 0, barWidth: 0, spacing: 0, barCount: 1, runWidth: 0)
        }
        let barWidth = max(1, height / waveBarAspectRatio)
        let spacing = barWidth * waveBarGapRatio
        let pitch = barWidth + spacing
        guard let forcedCount else {
            // Free-running: the count was chosen to fill the width, so re-fitting
            // the bars into it only takes up the rounding slack.
            let barCount = max(1, min(stageMaximumBars, Int(((width + spacing) / pitch).rounded())))
            let fittedBarWidth = waveBarWidth(fitting: barCount, into: width)
            return PillSpectrumGeometry(waveHeight: height,
                                        barWidth: fittedBarWidth,
                                        spacing: fittedBarWidth * waveBarGapRatio,
                                        barCount: barCount,
                                        runWidth: width)
        }
        // A *forced* count is the pill's, and is deliberately smaller than what
        // fits here. Stretching it across the full width would trade the shared
        // proportion rule away — fatter bars and wider gaps than a bar of this
        // height should have — and with it the thing that makes the morph one
        // scale factor: the pill's run is an exact fit for its count, so a page
        // run stretched to the full width is not the same shape, and no single
        // `scaleEffect` can carry both its height and its width. (Measured: a
        // scale that matched the height left the run 146 pt against the pill's
        // 112 pt.) So keep the target thickness and let the run be exactly as
        // wide as its bars need; it is centred in the space it was given.
        let barCount = max(1, min(stageMaximumBars, forcedCount))
        let n = CGFloat(barCount)
        let runWidth = min(width, n * barWidth + (n - 1) * spacing)
        return PillSpectrumGeometry(waveHeight: height,
                                    barWidth: barWidth,
                                    spacing: spacing,
                                    barCount: barCount,
                                    runWidth: runWidth)
    }

    /// Content area a carousel page gets inside the expanded panel. The row
    /// spacing is part of it: the tab bar and the pages sit in a `VStack` with
    /// `expandedRowSpacing` between them, and leaving it out made every
    /// prediction of the page's wave 8 pt too tall and 4 pt too high — enough
    /// for the travelling wave and the page's own to disagree visibly.
    /// The top border's page size specifically. Everything downstream of this
    /// — the pill⇄page wave morph and its two centre lines — is arithmetic
    /// about an island hanging from the top edge, and that is the only border
    /// the travelling wave runs on (see `NotchRootView.morphingWaveActive`).
    static var expandedPageSize: CGSize { expandedPageSize(on: .top) }

    /// What the spectrum page's wave settles at once the island is open. The
    /// pill's shrink-back animation starts from these metrics, so the run the
    /// user just watched appears to contract into the capsule.
    static var spectrumPageWaveGeometry: PillSpectrumGeometry {
        stageWaveGeometry(in: expandedPageSize)
    }

    /// How small the page's run has to start to match the pill's — i.e. the
    /// pill⇄page morph expressed as one number, since both ends follow the same
    /// proportion rule and therefore differ only in scale.
    static var pillToPageWaveScale: CGFloat {
        let pill = pillSpectrumGeometry(forWidth: UserSettings.shared.pillSpectrumWidth)
        let page = spectrumPageWaveGeometry
        guard page.waveHeight > 0 else { return 1 }
        return min(1, pill.waveHeight / page.waveHeight)
    }

    /// The page-sized end of the morph, holding the pill's bar *count*.
    ///
    /// The two ends normally resolve their own counts (19 in the pill, ~22 on
    /// the page), and a count that changes mid-flight re-buckets the spectrum
    /// on the very frames the eye is following. Keeping the count fixed makes
    /// the morph purely geometric: the same bars, further apart and taller.
    static func spectrumPageWaveGeometry(barCount: Int) -> PillSpectrumGeometry {
        // Straight through to the one implementation the page itself uses, so the
        // travelling overlay and the page's own run cannot drift apart. Deriving
        // it separately here looks harmless and drifts.
        stageWaveGeometry(in: expandedPageSize, barCount: barCount)
    }

    /// Centre of the pill's wave, measured from the island's top edge.
    static var pillWaveCentreY: CGFloat { currentCollapsedHeight / 2 }
    /// Centre of the spectrum page's wave, from the same origin.
    ///
    /// Everything above the page area has to be counted, not just the tab bar:
    /// the two sit in a `VStack` with `expandedRowSpacing` between them, so the
    /// page *starts* at `currentCollapsedHeight + expandedRowSpacing`. Leaving
    /// the spacing out put the travelling wave 8 pt above where the page draws
    /// its own — invisible in flight, but the run jumped down by exactly that
    /// much at the moment the page took the wave back over.
    ///
    /// Note this is not the same correction `expandedPageSize` already makes:
    /// there the spacing is subtracted from the page's *height*, here it is
    /// added to its *top*. Both are needed.
    static var pageWaveCentreY: CGFloat {
        currentCollapsedHeight + expandedRowSpacing + expandedPageSize.height / 2
    }

    /// The same for the fullscreen stage: the panel's page sits near the top of
    /// the screen, the fullscreen run in its middle.
    static func pageToFullscreenWaveOffset(screenSize: CGSize) -> CGFloat {
        (islandTopGap + pageWaveCentreY) - screenSize.height / 2
    }

    /// The same idea one step up: how small the fullscreen run starts so it
    /// grows out of the island page's.
    static func pageToFullscreenWaveScale(screenSize: CGSize) -> CGFloat {
        min(1, spectrumPageWaveGeometry.waveHeight / fullscreenWaveHeight(screenSize: screenSize))
    }

    /// Where the *pill's* wave sits on the screen, for the way back out.
    ///
    /// Escape takes the takeover straight home to the pill rather than back to
    /// the island's page: the island is collapsing at the same time, so aiming
    /// the run at a page that is busy disappearing left it landing on nothing.
    static func pillToFullscreenWaveOffset(screenSize: CGSize) -> CGFloat {
        (islandTopGap + pillWaveCentreY) - screenSize.height / 2
    }

    static func pillToFullscreenWaveScale(screenSize: CGSize) -> CGFloat {
        let pill = pillSpectrumGeometry(forWidth: UserSettings.shared.pillSpectrumWidth)
        return min(1, pill.waveHeight / fullscreenWaveHeight(screenSize: screenSize))
    }

    /// The run's height once it fills the screen. Shared by both ends above so
    /// they can only ever disagree about where the wave is going, never about
    /// how big it is when it gets there.
    private static func fullscreenWaveHeight(screenSize: CGSize) -> CGFloat {
        let full = stageWaveGeometry(in: CGSize(width: screenSize.width - stageInset * 4,
                                                height: screenSize.height - stageInset * 4))
        return full.waveHeight > 0 ? full.waveHeight : 1
    }

    /// The collapsed height currently in effect. Views without a
    /// `NotchViewModel` read this; the view model's `collapsedHeight` returns
    /// the same value, so there is one formula. In spectrum-only mode it grows
    /// with the width knob (see `pillSpectrumGeometry(forWidth:)`) — at the
    /// default that is 30 pt, which with `islandTopGap` still sits inside a
    /// physical notch's band; the widest settings deliberately hang below it,
    /// since that mode exists to be watched.
    static var currentCollapsedHeight: CGFloat {
        guard UserSettings.shared.pillSpectrumOnly else { return collapsedHeight }
        return pillSpectrumGeometry(forWidth: UserSettings.shared.pillSpectrumWidth).pillHeight
    }
    /// Font size of the shelf badge's item count in the collapsed pill.
    static let collapsedBadgeFontSize: CGFloat = 9
    /// The shelf badge (tray icon + item count, up to ~2 digits).
    static let collapsedBadgeWidth: CGFloat = 30
    /// Focus-timer segment in the collapsed pill (icon + monospaced readout).
    /// Its width is estimated as icon + inner spacing + chars × per-char width
    /// (see `NotchViewModel.collapsedWidth`); the per-char estimate errs
    /// generous — looseness is harmless, clipping is not.
    static let collapsedTimerFontSize: CGFloat = 11
    static let collapsedTimerIconSize: CGFloat = 10
    static let collapsedTimerIconWidth: CGFloat = 12
    static let collapsedTimerInnerSpacing: CGFloat = 3
    static let collapsedTimerCharWidth: CGFloat = 7
    /// Spacing between the collapsed HStack items.
    static let collapsedItemSpacing: CGFloat = 6
    /// Horizontal breathing room inside the pill (matches `CollapsedView`).
    static let collapsedContentPadding: CGFloat = 10
    /// Extra padding at each rounded end of the collapsed capsule. Kept small:
    /// the content is only ~13pt tall and vertically centered, so the corner
    /// curve barely intrudes at its edges — a tight pill reads more iPhone-like
    /// than a wide one; at the previous value the idle one-icon pill read
    /// as too wide.
    static let collapsedEndPadding: CGFloat = 4
    /// Horizontal inset of the expanded content (and the tab-page carousel clip
    /// in particular) from the island edge, clearing the rounded corners.
    static let expandedContentInset: CGFloat = 16

    static let expandedWidth: CGFloat = 460
    static let expandedHeight: CGFloat = 212

    /// The open island standing on a side border.
    ///
    /// Not the landscape island turned on its side: a 212 pt-thick portrait
    /// island leaves the pages ~150 pt to work in once the tab column and the
    /// insets have taken their share, which is narrower than the music page's
    /// cover and title need.
    ///
    /// Length is set by what has to fit rather than by symmetry with the
    /// landscape island: the tab column is five 38 pt slots and four gaps, so
    /// 214 pt, and the pages' own content clusters run 130–200 pt. 420 pt (the
    /// first try, a straight swap of the landscape length) left every page a
    /// small cluster adrift in a field of black.
    static let expandedVerticalLength: CGFloat = 320
    static let expandedVerticalThickness: CGFloat = 264

    /// The open island's size on a given border.
    static func expandedSize(on dock: NotchDock) -> CGSize {
        dock.isHorizontal
            ? CGSize(width: expandedWidth, height: expandedHeight)
            : dock.size(length: expandedVerticalLength, thickness: expandedVerticalThickness)
    }

    /// Content area one carousel page gets on a given border. The band the tab
    /// strip occupies, the gap after it and the padding at the far edge all
    /// come off the thickness; the insets come off the length.
    static func expandedPageSize(on dock: NotchDock) -> CGSize {
        let island = expandedSize(on: dock)
        let (length, thickness) = dock.lengthAndThickness(of: island)
        return dock.size(
            length: length - expandedContentInset * 2,
            thickness: thickness - currentCollapsedHeight - expandedBottomPadding - expandedRowSpacing
        )
    }

    /// One tab's slot on a given border: the strip runs along the border, so
    /// the slot is long in that direction and thin across it — thin enough to
    /// sit inside the pill's own band, which is what keeps the selected glyph
    /// on the spot the pill handed it over at.
    static func tabItemSize(on dock: NotchDock) -> CGSize {
        dock.size(length: tabItemWidth, thickness: tabItemHeight)
    }

    /// Width of the `.band` stage: a capsule holding every tab with breathing
    /// room to the rounded ends. Tuned against the pill, not against the row —
    /// five icon-only tabs come to ~210 pt and sit well inside it.
    static let bandWidth: CGFloat = 380

    /// The `.band` stage's length on a given border. A portrait island is
    /// shorter than the landscape band capsule, and a transient stage longer
    /// than the island it is on the way to is a silhouette that grows before it
    /// shrinks — so on a side border the band stops a little short of the open
    /// island instead.
    static func bandLength(on dock: NotchDock) -> CGFloat {
        dock.isHorizontal ? bandWidth : expandedVerticalLength - bandVerticalInset
    }
    /// How far the side-border band capsule stops short of the open island.
    static let bandVerticalInset: CGFloat = 24
    /// Width of the `.solo` stage — one icon, its button padding, and the
    /// capsule's own end padding. See `NotchViewModel.soloWidth`.
    static let soloBaseWidth: CGFloat = 74

    /// Point size the tab glyphs are drawn at — in the tab bar and, because the
    /// pill's idle glyph is the very same `TabIcon`, in the pill too.
    ///
    /// Ceilinged by the pill, not by the tab bar: every state but `.expanded`
    /// draws this glyph inside the 24pt band, clipped to a capsule. At 17pt
    /// `radio.fill` measures 24×23 — taller than the band it sits in and wider
    /// than the straight section between the capsule's rounded ends, so the pill
    /// shaved its corners. 15pt puts the largest glyph at 22×20, which clears the
    /// band by 2pt top and bottom. (Sizes are `NSImage.SymbolConfiguration`
    /// measurements, not estimates.)
    static let tabIconSize: CGFloat = 15
    /// Tap target and selection capsule for one tab. Fixed for every tab,
    /// selected or not, so marking the selection cannot move the row. Exactly
    /// the band's height: the capsule is the band, filled.
    static let tabItemWidth: CGFloat = 38
    static let tabItemHeight: CGFloat = 24
    /// Fill behind the selected tab, standing in for the title it replaced.
    static let tabSelectionFill: Double = 0.16
    /// Breathing room above the tab row while the island is open.
    ///
    /// The row otherwise sits in the collapsed pill's own 24 pt band, flush to
    /// the top, because that is what puts the tab icons on the same y as the
    /// pill's glyph and makes the collapse handover purely horizontal. At pill
    /// size that band is the whole island and the tightness reads as correct; at
    /// 212 pt it reads as the icons being pressed against the rim.
    ///
    /// Applied only while the island is *open*, and pushing the whole band down
    /// rather than growing it. Both halves of that matter. Growing the band
    /// re-centres the glyphs inside a taller box, which lands them 4.5pt below
    /// where the pill wants them and turns the handover into a jump. And every
    /// stage but `.expanded` is 24pt tall — including `.band`, which shows all
    /// five tabs at pill height — so an inset that keyed off "all tabs showing"
    /// pushed the row 9pt down inside a 24pt island and the clip ate the bottom
    /// third of every icon.
    static let tabBarTopInset: CGFloat = 9
    static let tabBarSpacing: CGFloat = 6
    /// Foreground opacity of an unselected tab (selected is fully opaque).
    static let tabInactiveOpacity: Double = 0.55
    /// Vertical spacing between the tab bar and the page carousel when expanded.
    static let expandedRowSpacing: CGFloat = 8
    /// Bottom padding below the page carousel when expanded.
    static let expandedBottomPadding: CGFloat = 20

    /// How long the island rests in each transient stage before advancing.
    /// Tuned frame-by-frame (see `IslandChoreographySheetTests`): each rest is
    /// deliberately *shorter* than the hop animation's settling time, so the
    /// next stage retargets the spring while the silhouette is still moving —
    /// the walk reads as one continuous gesture. At the earlier values
    /// (0.30–0.35, ≈ the settling time) every hop braked to a near-standstill
    /// before the next began: a visible staircase. The stages still fire in
    /// order, so the content choreography (pages out → tabs out → labels out,
    /// each a 0.15–0.16 s fade) keeps fitting inside its stage's rest.
    static let bandCollapseDelay: TimeInterval = 0.18  // .band → .solo
    static let soloCollapseDelay: TimeInterval = 0.18  // .solo → .condensing
    /// How long the condensing stage (icon centres, capsule narrows to pill
    /// width) runs before the pill content swaps in. It has to outlast the
    /// *icon's* travel, not just the capsule's, because the handover is a hard
    /// cut: the glyph must already be where the pill will draw it.
    ///
    /// That travel used to be the reason this stage was so long. On the
    /// capsule's own `smooth(0.55)` spring the icon needed ~0.7 s to land
    /// sub-pixel, so the swap waited 0.55 s past `.condensing` — and because
    /// the wait is skipped whenever the pill has hero content (music, other
    /// system audio, a running timer), the very same gesture closed the island
    /// in 0.36 s or in 0.94 s depending on whether anything happened to be
    /// audible. Nothing on screen explains the difference, so it reads as the
    /// notch randomly closing in slow motion.
    ///
    /// The row now condenses on its own, much faster clock
    /// (`tabCondenseAnimation`), which is what the capsule's calm settling was
    /// holding up. 88 pt of travel — the widest slot offset, Musik's — is
    /// sub-pixel 0.36 s after `.solo`, so one plain rest is enough and every
    /// collapse takes the same time.
    static let condenseSwapDelay: TimeInterval = 0.18
    /// Expand rests are near-zero: opening must move the instant the hover
    /// lands, and the expand hops exist as spring waypoints (each retargeted
    /// mid-flight), not as shapes to linger on. Stages that don't change the
    /// island at all for the current content are skipped entirely — see
    /// `NotchWindowController.stageRestDelay`.
    static let condenseExpandDelay: TimeInterval = 0.03  // .condensing → .solo
    static let soloExpandDelay: TimeInterval = 0.07      // .solo → .band
    static let bandExpandDelay: TimeInterval = 0.09      // .band → .expanded

    /// Fade of the labels and the unselected tabs as the capsule narrows around
    /// the surviving content. Deliberately much faster than the width spring:
    /// text must be gone *before* the narrowing rounded ends sweep over its
    /// position, or clipped letter fragments linger at the rim.
    static var condenseFadeAnimation: Animation { Motion.gate(.easeOut(duration: 0.15)) }

    /// The tab row's own clock for shedding its unselected tabs and gathering
    /// the surviving glyph at the capsule centre (and, on the way up, letting it
    /// back out to its slot).
    ///
    /// Deliberately not the capsule's spring. The capsule is a big shape whose
    /// calm 0.55 s settling is the point; the icon is one glyph with 88 pt to
    /// cover, and riding the capsule's spring it was still visibly creeping
    /// inward half a second in — the slowest thing on screen during a collapse,
    /// and the reason the hard-cut handover had to wait so long for it. On its
    /// own bounce-free clock it is home in under a third of a second while the
    /// capsule keeps settling around it, which is the same "content lands early
    /// in a still-moving island" pattern the pages already use.
    static var tabCondenseAnimation: Animation { Motion.gate(.smooth(duration: 0.28)) }

    // The pill ⇄ condensed-icon handover is a hard cut (see `iconHandover`
    // in NotchView) — it deliberately has no timing constants: every
    // overlap-based variant (crossfade, hold-opaque) drew both near-identical
    // glyphs at once and their sub-point offset read as a brightness blink.

    /// Delay before the *unselected* tabs fade in once the band assembles on
    /// expand. The selected icon travels from the capsule centre to its slot
    /// during the band/final hops, passing over its neighbours' positions —
    /// fading them in immediately painted them under the still-flying icon,
    /// which reads as one glyph overlapping another. Timed so the fade starts
    /// once the flight is essentially home: the capsule leads, its content
    /// follows.
    static let tabJoinFadeDelay: TimeInterval = 0.20

    /// When music plays, the collapse hands the tab bar off to the now-playing
    /// pill hero (cover + spectrum) at the `.solo` stage. Those two are *different*
    /// content, so unlike `pillHandoverFade` this is a genuine crossfade —
    /// a hold-opaque handover would show them overlapping. Slightly longer
    /// for a smooth dissolve as the capsule narrows.
    static let heroCrossfadeDuration: TimeInterval = 0.24
    /// The arriving side of the hero crossfade starts this much later than the
    /// departing side — sequenced, not overlapped: the wave dissolves first,
    /// *then* the tab bar materialises. At a shorter delay the two were both
    /// half-visible for ~0.14 s (the composite filmstrip showed tab icons
    /// appearing around a still-visible wave — the "mush" that read as
    /// buggy). Set to the crossfade duration minus a hair, so the departing
    /// side is ≥ 90% gone before the arriving side begins; the black island
    /// carries the brief quiet moment between them.
    static let heroCrossfadeInsertDelay: TimeInterval = 0.22

    /// Width of the collapsed pill while a live activity is showing.
    static let activityWidth: CGFloat = 220
    /// Wider pill for the audio-route activity (bigger icon + device name + battery)
    /// so a connecting device reads clearly.
    static let activityRouteWidth: CGFloat = 264
    /// A wordless activity on a side border: just the glyph.
    static let activityVerticalLength: CGFloat = 44
    /// The same with a progress bar under it (the volume and brightness HUDs).
    static let activityVerticalProgressLength: CGFloat = 104

    /// How long the collapsed capsule runs while a live activity owns it.
    ///
    /// On a side border the activity gives up its words. A device name turned
    /// on its side next to an upright glyph reads as a rendering fault rather
    /// than as a vertical pill, and what the pill is actually *for* — which
    /// device, how loud — survives in the glyph and the bar. So a vertical
    /// activity is the glyph, plus its progress when it has any.
    static func activityLength(isRoute: Bool, hasProgress: Bool, on dock: NotchDock) -> CGFloat {
        guard !dock.isHorizontal else { return isRoute ? activityRouteWidth : activityWidth }
        return hasProgress ? activityVerticalProgressLength : activityVerticalLength
    }

    // MARK: Island silhouette (iPhone Dynamic Island style)

    /// Gap between the physical top screen edge and the island — like the
    /// iPhone's Dynamic Island floating in the status bar. Identical in both
    /// states so the top edge stays put while the island morphs.
    static let islandTopGap: CGFloat = 2
    /// Expanded corner radius — the iPhone's expanded Live Activity uses ~40pt;
    /// slightly tighter here since the panel band is denser.
    static let expandedCornerRadius: CGFloat = 36

    /// Pure black, iPhone-style — separation from a dark backdrop comes from
    /// the highlight rim and the shadow, not from the fill.
    static let islandFill = Color.black
    /// Hairline highlight rim: brighter along the top edge, fading out toward
    /// the bottom — sells the island as an object floating above the backdrop.
    static let islandStrokeTopOpacity: Double = 0.10
    static let islandStrokeBottomOpacity: Double = 0.02
    static let islandStrokeWidth: CGFloat = 1

    /// Drop shadow under the floating island. A detached island has nothing else
    /// to read as elevated, so this carries more weight than a docked one's would.
    static let islandShadowOpacityExpanded: Double = 0.55
    static let islandShadowOpacityCollapsed: Double = 0.35
    static let islandShadowRadius: CGFloat = 14
    static let islandShadowYOffset: CGFloat = 5

    // MARK: Panel margins

    /// The fixed panel is larger than the visible island so the SwiftUI
    /// island's shadow has room to render. Only the island animates inside.
    /// The vertical margin also absorbs the top gap the island floats below.
    static let panelHorizontalMargin: CGFloat = 60
    static var panelVerticalMargin: CGFloat { 24 + islandTopGap }

    // MARK: Dragging the island to another border

    /// How far the cursor must travel with the button down before a press on
    /// the island becomes a drag of the whole panel. Small enough that dragging
    /// feels immediate, large enough that a click with a shaky hand is still a
    /// click.
    static let panelDragThreshold: CGFloat = 4
    /// Within this much of an edge's centre a released drag lands exactly
    /// centred — the way back to the notch's home pose without aiming.
    static let dockCentreSnap: CGFloat = 14
    /// And within this much of either *end* of a border it goes into that
    /// corner. Wider than the centre snap because a corner is a bigger target
    /// to want and a harder one to hit: the island cannot be dragged past the
    /// screen edge, so the gesture is "shove it into the corner" rather than
    /// "place it exactly".
    static let dockCornerSnap: CGFloat = 48
    /// The glide onto the border once the button comes up. The panel's frame
    /// (AppKit) and the island's alignment inside it (SwiftUI) both animate,
    /// so they share one duration or the island slides out of its own panel.
    static let dockSettleDuration: TimeInterval = 0.22
    static var dockSettleAnimation: Animation { Motion.gate(.easeInOut(duration: dockSettleDuration)) }

    // MARK: Safari fullscreen dodge

    /// Gap between Safari's URL/search field and the dodged pill's left edge.
    static let safariDodgeGap: CGFloat = 70
    /// How far above the URL field's vertical centre the dodged pill sits —
    /// the AX frame hugs the text, the visible container reads higher.
    static let safariDodgeRaise: CGFloat = 8
    /// Minimum clearance the dodged pill keeps from the screen's right edge.
    static let safariDodgeEdgeMargin: CGFloat = 16

    // MARK: Hover detection

    /// Extra tolerance around the visible collapsed pill before hover counts
    /// as "on the notch". Kept tiny so it only triggers over the pill.
    static let collapsedHoverInset: CGFloat = 4
    /// Outward tolerance around the *expanded* island before a cursor counts as
    /// having left it. Gives the collapse boundary a little hysteresis so a
    /// graze along the exact visible edge doesn't commit the slow collapse
    /// walk — "open" was already padded (`collapsedHoverInset`), this pads
    /// "stay open" to match.
    static let expandedHoverInset: CGFloat = 6
    /// Bleed the hover rect above the physical top edge: the cursor's y at the
    /// very top equals `screen.frame.maxY`, and `NSRect.contains` treats the top
    /// edge as exclusive (`y < maxY`). Without this the notch refuses to open at
    /// the screen edge.
    static let hoverTopBleed: CGFloat = 8
    /// Extra width/height added to the hit-test rect used by `NotchContainerView`.
    static let hitTestWidthPadding: CGFloat = 8
    static let hitTestHeightPadding: CGFloat = 6

    // MARK: Timing & animation

    /// Fade duration when the whole panel hides or reappears (idle hide, and
    /// any other `PanelPresencePolicy` transition that may animate).
    static let idleHideFadeDuration: TimeInterval = 0.25
    /// Delay before collapsing after a drag exits, so brief exits don't flicker.
    static let collapseDelay: TimeInterval = 0.12
    /// Grace period before the island force-closes after the cursor leaves
    /// while the capture field is still focused (e.g. right after submitting
    /// a note, which re-focuses it for the next thought). Long enough to
    /// glance at the keyboard, short enough that the island doesn't stay open
    /// forever — nothing else ever un-focuses the field on its own.
    static let interactionLockGraceDelay: TimeInterval = 2.5
    /// Minimum vertical scroll magnitude to treat a swipe as a gesture.
    static let gestureScrollThreshold: CGFloat = 6
    /// A horizontal swipe only pages tabs once per gesture: a new gesture is
    /// recognized when this long has passed since the last horizontal scroll event
    /// (so trackpad momentum within one swipe doesn't flip through several tabs).
    static let tabSwipeGestureGap: TimeInterval = 0.25

    /// Silhouette morph for live-activity pills appearing/dismissing in the
    /// collapsed pill (not the expand/collapse walk). A small, lively spring —
    /// damping low enough for a visible snap, like the iPhone's island pills.
    static var islandMorphAnimation: Animation { Motion.gate(.spring(response: 0.40, dampingFraction: 0.74)) }

    /// The page ⇄ fullscreen leg of the spectrum morph.
    ///
    /// Its own spring because it is not the same journey as the other two. The
    /// pill⇄page morph grows the run by roughly 4× inside the island; this one
    /// takes it from the island to the whole screen — several times the
    /// distance and the scale, driven at `islandMorphAnimation`'s 0.40 response
    /// it read as a snap rather than a takeover. Longer response for the
    /// distance, and damped nearly flat: at page size a little overshoot is a
    /// bit of life, at screen size the same proportional overshoot is a wobble
    /// across the whole display.
    static var spectrumFullscreenMorphAnimation: Animation { Motion.gate(.spring(response: 0.58, dampingFraction: 0.88)) }

    /// Silhouette morph (frame + corner radius) for each *collapse* stage. A
    /// bounce-free `.smooth` spring: collapsing reads as a calm, silky settling,
    /// never a snap or wobble — overshoot on *closing* looks wrong.
    static var islandCollapseAnimation: Animation { Motion.gate(.smooth(duration: 0.55)) }
    /// Each *intermediate* expand stage — quicker than the collapse so opening
    /// on hover feels snappy, with a whisper of bounce for life. These hops are
    /// re-animated almost immediately, so real overshoot would just wobble.
    static var islandExpandAnimation: Animation { Motion.gate(.snappy(duration: 0.30, extraBounce: 0.1)) }
    /// The *final* expand hop (`.band → .expanded`) is the only one that rests,
    /// so it can afford a genuine overshoot-and-settle — the Dynamic-Island
    /// "pop" that the intermediate hops must not have.
    static var islandExpandFinalAnimation: Animation { Motion.gate(.spring(response: 0.42, dampingFraction: 0.70)) }

    /// Content fade-in on expand: slightly delayed so it appears once the
    /// silhouette has grown enough room, then springs out of the pill with the
    /// same character as the silhouette's final pop.
    static var contentInsertAnimation: Animation { Motion.gate(.spring(response: 0.35, dampingFraction: 0.75).delay(0.05)) }
    /// Content fade-out on collapse: fast easeIn so the content is gone *before*
    /// the silhouette finishes shrinking (nothing lingers outside the shape).
    /// Long enough that the active tab glyph's matched-geometry flight into the
    /// pill is readable before the rest fades. Never springy — removal that
    /// bounces reads as broken.
    static var contentRemoveAnimation: Animation { Motion.gate(.easeIn(duration: 0.16)) }
    /// Starting scale of inserted content — the "grow out of the pill" morph,
    /// pronounced enough to register now that the insert is a spring.
    static let contentMorphScale: CGFloat = 0.93

    /// Switching tabs (tap button and horizontal swipe both use it) — drives the
    /// page carousel offset and the tab bar's sliding selection capsule. A hint
    /// of overshoot; the pages are clipped, so it can't escape the island.
    static var tabChangeAnimation: Animation { Motion.gate(.spring(response: 0.35, dampingFraction: 0.74)) }

    /// Scale of the tab pages that aren't front — they sit slightly shrunken and
    /// dimmed beside the active page and grow in as they slide to front.
    static let tabPageInactiveScale: CGFloat = 0.96
    /// Opacity of the non-front tab pages while the carousel slides.
    static let tabPageInactiveOpacity: CGFloat = 0.3

    /// How long after the island reaches `.expanded` the page carousel is
    /// allowed to mount. Building all five tab pages is the single heaviest
    /// main-thread moment of the whole walk, and it used to land exactly
    /// mid-flight of the final spring — a visible dropped-frame hitch.
    /// Deferred past the spring's fast phase, the shape
    /// morphs on an empty island and the content materialises into a nearly
    /// still frame — the iPhone's own trick.
    static let pagesSettleDelay: TimeInterval = 0.18

    /// How long after the wave has set off for its place the tab bar waits
    /// before fading up. Long enough that the two read as separate beats —
    /// island and wave first, chrome last — short enough not to feel withheld.
    static let chromeRevealDelay: TimeInterval = 0.16

    /// How long CaptureView waits before mounting its AppKit-backed text field.
    /// NSTextField ignores SwiftUI clip shapes, so the real field must not exist
    /// while the island morph (spring response 0.42) or the tab carousel spring
    /// (response 0.38) is still moving — a SwiftUI placeholder stands in until then.
    static let captureFieldMountDelay: TimeInterval = 0.45
    /// How wide the capture field is allowed to get. 260 left it floating in the
    /// middle of a 428 pt page with dead space either side, which read as an
    /// unfinished layout rather than as a deliberately small target.
    static let captureFieldWidth: CGFloat = 372
}
