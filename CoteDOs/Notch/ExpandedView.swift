import SwiftUI

struct ExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var shelf: FileShelfModel
    @ObservedObject var pomodoro: PomodoroManager
    @ObservedObject var capture: ObsidianCapture
    @ObservedObject var spectrum: SpectrumAnalyzer
    /// True while `NotchRootView` is drawing the spectrum itself, above this
    /// view, so it can travel in from the pill as one object — the page then
    /// leaves a hole exactly where the wave will land, and takes it back over
    /// once the flight is done.
    var spectrumWaveDrawnByOverlay: Bool = false
    /// Bar count the page's wave must hold so that taking over from the
    /// travelling one is invisible. nil → the page resolves its own.
    var spectrumWaveBarCount: Int?
    /// Icon and accent of whichever app is making the sound, so the spectrum
    /// page is coloured by the audio it is actually drawing.
    @ObservedObject private var sourceApp = SourceAppAccent.shared

    /// The colours the spectrum page's wave draws with — the same answer the
    /// pill and the travelling overlay resolve, so the morph doesn't change
    /// colour halfway through. See `WaveTints`.
    private var waveTints: WaveTints {
        WaveTints.resolve(nowPlaying: nowPlaying, sourceBundleID: spectrum.sourceBundleID, sourceAppTint: sourceApp.tint)
    }

    private var pageIndex: Int {
        NotchViewModel.Tab.allCases.firstIndex(of: viewModel.selectedTab) ?? 0
    }

    /// False during the band collapse stage: the island has shrunk to just the
    /// tab-bar capsule, the pages are gone, only the bar remains (and must stay
    /// the *same view* as in the expanded state, or its icons would visibly
    /// re-appear instead of simply staying put). Also false until the island
    /// has *rested* in `.expanded` for a beat (`pagesSettled`): building all
    /// five pages is the heaviest view-mount of the app, and doing it
    /// mid-spring dropped frames — the shape morphs first, the content
    /// materialises into a nearly still island.
    private var showsPages: Bool { viewModel.islandState == .expanded && viewModel.pagesSettled }

    /// The border the island is parked on — everything below is laid out along
    /// it, and mirrored end for end so the tab band always hugs it.
    private var dock: NotchDock { viewModel.placement.dock }

    var body: some View {
        AxisStack(axis: dock.isHorizontal ? .vertical : .horizontal,
                  spacing: showsPages ? NotchLayout.expandedRowSpacing : 0) {
            if dock.bandLeads { tabBar }
            carousel
            if !dock.bandLeads { tabBar }
        }
        // Inset the content (and the carousel clip in particular) from the
        // island edge so it clears the rounded corners; sliding pages must not
        // poke past the dark body onto the wallpaper. Along the border, since
        // that is the direction the pages travel in.
        .padding(dock.isHorizontal ? .horizontal : .vertical, NotchLayout.expandedContentInset)
        // Breathing room at the *far* edge from the border — the open end.
        .padding(farEdge, showsPages ? NotchLayout.expandedBottomPadding : 0)
        .foregroundStyle(.white)
    }

    /// The island's open end: the edge opposite the one it is docked to.
    private var farEdge: Edge.Set {
        switch dock {
        case .top: return .bottom
        case .bottom: return .top
        case .leading: return .trailing
        case .trailing: return .leading
        }
    }

    @ViewBuilder private var tabBar: some View {
        // The tab bar occupies exactly the collapsed pill's band (flush against
        // the border, same thickness), so its icons sit on the same line as the
        // pill's glyph — the hero flight between them runs along the border,
        // never diagonally.
        NotchTabBar(
            selection: $viewModel.selectedTab,
            // .band/.expanded keep every tab; .solo/.condensing keep only the
            // selected one, so the capsule can narrow onto it.
            showsAllTabs: viewModel.islandState == .expanded || viewModel.islandState == .band,
            isOpen: viewModel.islandState == .expanded,
            dock: dock
        )
        .frame(maxWidth: dock.isHorizontal ? .infinity : nil,
               maxHeight: dock.isHorizontal ? nil : .infinity)
        // The pill's own band, at every stage — that is what puts the tab
        // glyphs exactly where the pill's glyph sits, which is the whole
        // premise of the hard-cut handover. The open island's breathing room
        // is padding *outside* the band, so it moves the band inward without
        // ever resizing it.
        .frame(width: dock.isHorizontal ? nil : NotchLayout.currentCollapsedHeight,
               height: dock.isHorizontal ? NotchLayout.currentCollapsedHeight : nil)
        // Breathing room between the border and the row. On the border side at
        // every dock: it is the gap the island's edge leaves, not a top margin.
        .padding(borderEdge, viewModel.islandState == .expanded ? NotchLayout.tabBarTopInset : 0)
        // No opacity gate on the row: the selected glyph is the pill's
        // glyph, still on screen, and the opening is the collapse played
        // backwards. It glides from the capsule's centre out to its slot —
        // 88 pt, if you were on Musik — while its neighbours fade in behind
        // it (`tabJoinFadeDelay`). Hiding the row for that move and fading
        // it back afterwards is what made the icon read as flying away
        // rather than travelling somewhere.
    }

    /// The edge the island is docked against.
    private var borderEdge: Edge.Set {
        switch dock {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    // The pages live in a carousel that slides as one strip. Unlike
    // insertion/removal transitions this can't get the direction wrong on
    // quick back-and-forth swipes — the offset is a pure function of the
    // selected index. The strip runs along the border, so on a side dock the
    // pages stack downward and slide vertically, in the same direction the tab
    // column reads.
    @ViewBuilder private var carousel: some View {
            if showsPages {
                GeometryReader { geo in
                    AxisStack(axis: dock.isHorizontal ? .horizontal : .vertical, spacing: 0) {
                        page(.music, in: geo.size) {
                            NowPlayingView(nowPlaying: nowPlaying, spectrum: spectrum,
                                           portrait: !dock.isHorizontal)
                        }
                        page(.spectrum, in: geo.size) {
                            // The whole page is the wave. Colours follow
                            // whichever app is making the sound — the track's
                            // cover when that's the player, the source app's
                            // icon accent otherwise.
                            //
                            // Unless the wave is the one travelling in from the
                            // pill, in which case it is drawn above this page
                            // and the page itself is only the tap target that
                            // hands it the whole screen.
                            if spectrumWaveDrawnByOverlay {
                                Color.clear
                            } else {
                            let tints = waveTints
                            SpectrumStageView(
                                levels: spectrum.bands,
                                isLive: spectrum.isLive,
                                isActive: nowPlaying.screensAwake,
                                tint: tints.primary,
                                coverBars: tints.coverBars,
                                fixedBarCount: spectrumWaveBarCount,
                                // Standing on a side border, the run stands up
                                // with the island: bars stacked down the page,
                                // growing out of the edge.
                                axis: dock.isHorizontal ? .horizontal : .vertical
                            )
                            }
                        }
                        // Click the page to hand the wave the whole screen;
                        // Escape brings it back (see
                        // `SpectrumFullscreenController.installKeyMonitor`). The
                        // swipe-down/swipe-up pair still works — this is the
                        // same step on the same axis, reachable without a
                        // trackpad gesture. `contentShape` because the page is
                        // mostly empty space, and while the overlay owns the
                        // wave it is literally `Color.clear`.
                        .contentShape(Rectangle())
                        .onTapGesture { SpectrumFullscreen.shared.present() }
                        page(.files, in: geo.size) { ShelfView(shelf: shelf) }
                        page(.capture, in: geo.size) { CaptureView(capture: capture, viewModel: viewModel) }
                        page(.timer, in: geo.size) {
                            PomodoroView(pomodoro: pomodoro, portrait: !dock.isHorizontal)
                        }
                    }
                    .offset(x: dock.isHorizontal ? -CGFloat(pageIndex) * geo.size.width : 0,
                            y: dock.isHorizontal ? 0 : -CGFloat(pageIndex) * geo.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .transition(.notchContent)
            }
    }

    @ViewBuilder
    private func page<Content: View>(
        _ tab: NotchViewModel.Tab, in size: CGSize, @ViewBuilder content: () -> Content
    ) -> some View {
        let isFront = viewModel.selectedTab == tab
        content()
            .frame(width: size.width, height: size.height)
            .scaleEffect(isFront ? 1 : NotchLayout.tabPageInactiveScale)
            .opacity(isFront ? 1 : NotchLayout.tabPageInactiveOpacity)
            // Clipped-away pages are still hit-testable; don't let them swallow
            // clicks or file drops meant for the front page.
            .allowsHitTesting(isFront)
    }
}
