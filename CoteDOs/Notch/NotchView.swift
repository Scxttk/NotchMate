import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var shelf: FileShelfModel
    @ObservedObject var activities: ActivityManager
    @ObservedObject var pomodoro: PomodoroManager
    @ObservedObject var capture: ObsidianCapture
    @ObservedObject var spectrum: SpectrumAnalyzer
    /// Observed so `islandWidth` re-evaluates when the spectrum-only pill mode
    /// flips — the pill's width formula changes with it.
    @ObservedObject private var settings = UserSettings.shared
    /// Observed so the island's own wave stands down while the fullscreen
    /// takeover is up: it is completely covered by that window and would
    /// otherwise keep redrawing 30 times a second behind it.
    @ObservedObject private var fullscreen = SpectrumFullscreen.shared
    /// Icon and accent of whichever app is actually making the sound, so a
    /// Safari video tints the wave with Safari's blue instead of the paused
    /// player's cover.
    @ObservedObject private var sourceApp = SourceAppAccent.shared

    /// The colours every wave in this view draws with — one answer, so the
    /// pill's run and the page's run can't disagree mid-morph.
    private var waveTints: WaveTints {
        WaveTints.resolve(nowPlaying: nowPlaying, sourceBundleID: spectrum.sourceBundleID, sourceAppTint: sourceApp.tint)
    }

    /// Run the audio tap whenever the screen is on, regardless of whether
    /// anything is playing — `spectrum.hasSignal` (derived from the tapped
    /// signal itself, see `SpectrumAnalyzer`) is what tells the rest of the UI
    /// whether audio is actually audible right now. Gated on `screensAwake` so
    /// it isn't tapping/FFT-ing to a dark display.
    private func syncSpectrum() {
        if nowPlaying.screensAwake {
            spectrum.start()
        } else {
            spectrum.stop()
        }
    }

    /// True whenever the pill hero (cover-or-generic-icon + live wave) should
    /// take over the collapsed pill — Spotify/Music playing, or any other
    /// system audio (browser video, calls, …) with no scriptable track to show.
    private var hasAudioHero: Bool {
        nowPlaying.isPlaying || spectrum.hasSignal
    }

    private var dock: NotchDock { viewModel.placement.dock }

    /// The island's silhouette for the current state, as a size on the border
    /// it is on. Every case below is a *length* along that border — the
    /// thickness is the pill's own band, except when the island is open.
    private var islandSize: CGSize {
        viewModel.islandState == .expanded
            ? viewModel.expandedIslandSize
            : dock.size(length: islandLength, thickness: viewModel.collapsedHeight)
    }

    private var islandLength: CGFloat {
        switch viewModel.islandState {
        case .expanded:
            return dock.lengthAndThickness(of: viewModel.expandedIslandSize).length
        case .band:
            return NotchLayout.bandLength(on: dock)
        case .solo:
            // Playing or timing: the pill hero (cover + spectrum and/or timer
            // readout) has already taken over, so the capsule is pill-width —
            // no tab label to make room for.
            if hasAudioHero || pomodoro.pillText != nil {
                return viewModel.collapsedWidth(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText)
            }
            // Otherwise hug the single surviving tab group (selected icon + label).
            return viewModel.soloWidth
        case .condensing:
            // Already the pill's width: the capsule narrows onto the selected
            // icon during this stage, so the final swap changes nothing.
            return viewModel.collapsedWidth(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText)
        case .collapsed:
            if let activity = activities.current {
                return NotchLayout.activityLength(isRoute: activity.kind == .audioRoute,
                                                  hasProgress: activity.progress != nil,
                                                  on: dock)
            }
            return viewModel.collapsedWidth(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText)
        }
    }

    /// Horizontal shift of the island *frame* off screen centre: with the audio
    /// hero active, the hero core stays centred and the trailing segments
    /// (timer, badge) grow rightward — so the whole capsule sits asymmetric by
    /// half the trailing width. Mirrors the `islandWidth` switch: the pill hero
    /// takes over from `.solo` on, so those stages already rest at the shifted
    /// position; `.expanded`/`.band` and activity pills stay centred. The shift
    /// changes inside the very same `withAnimation` transactions as the width,
    /// so it rides the staged walk's tuned springs.
    private var islandXOffset: CGFloat {
        // Only at home: the shift exists to keep the hero core on the screen's
        // centre line, where the physical notch is. Parked on a border it would
        // just be an off-centre capsule.
        guard viewModel.placement.isHome else { return 0 }
        switch viewModel.islandState {
        case .expanded, .band:
            return 0
        case .solo, .condensing, .collapsed:
            if viewModel.islandState == .collapsed, activities.current != nil { return 0 }
            return viewModel.collapsedTrailingShift(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText)
        }
    }

    /// Which corner of the panel the island is pinned to — the docked border.
    /// Pinned there and free at the opposite side, so opening it grows the
    /// island *inward* instead of off the screen edge it is glued to. Mirrored
    /// in AppKit by `NotchPlacement.islandRect(inPanel:size:gap:shift:)`, which
    /// is what the hit and hover rects are built from.
    /// Where the island sits inside the panel: against its border, and — in a
    /// corner — against that end of it too. The AppKit mirror of this is
    /// `NotchPlacement.islandRect(inPanel:size:gap:shift:)`, and the two must
    /// agree or the island is drawn somewhere the cursor rects aren't.
    private var dockAlignment: Alignment {
        let placement = viewModel.placement
        switch placement.dock {
        case .top, .bottom:
            let vertical: VerticalAlignment = placement.dock == .top ? .top : .bottom
            switch placement.anchor {
            case .start:  return Alignment(horizontal: .leading, vertical: vertical)
            case .end:    return Alignment(horizontal: .trailing, vertical: vertical)
            case .centre: return Alignment(horizontal: .center, vertical: vertical)
            }
        case .leading, .trailing:
            let horizontal: HorizontalAlignment = placement.dock == .leading ? .leading : .trailing
            switch placement.anchor {
            // A vertical border runs downward, so its start is the top.
            case .start:  return Alignment(horizontal: horizontal, vertical: .top)
            case .end:    return Alignment(horizontal: horizontal, vertical: .bottom)
            case .centre: return Alignment(horizontal: horizontal, vertical: .center)
            }
        }
    }

    /// The island's *own* alignment: against its border, centred along it.
    ///
    /// Deliberately corner-blind, unlike `dockAlignment`. A corner decides
    /// where the island sits inside the panel; inside the island everything
    /// still runs from the middle out. Handing the corner down here pinned the
    /// travelling wave's page-sized frame to one end and left the shrunken run
    /// hanging off the side of the pill.
    private var borderAlignment: Alignment {
        switch viewModel.placement.dock {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    /// The edges the island floats `islandTopGap` off: its border always, plus
    /// the end of that border when it is parked in a corner.
    private var dockEdge: Edge.Set {
        let placement = viewModel.placement
        var edges: Edge.Set
        switch placement.dock {
        case .top: edges = .top
        case .bottom: edges = .bottom
        case .leading: edges = .leading
        case .trailing: edges = .trailing
        }
        switch (placement.dock.isHorizontal, placement.anchor) {
        case (_, .centre): break
        case (true, .start): edges.insert(.leading)
        case (true, .end): edges.insert(.trailing)
        case (false, .start): edges.insert(.top)
        case (false, .end): edges.insert(.bottom)
        }
        return edges
    }

    var body: some View {
        ZStack(alignment: dockAlignment) {
            Color.clear
            island
                // The island floats detached off the screen edge, iPhone-style.
                .padding(dockEdge, NotchLayout.islandTopGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dockAlignment)
        .onAppear { syncSpectrum() }
        .onChange(of: nowPlaying.isPlaying) { _, playing in
            // Deliberately does *not* switch to the music tab any more. The
            // selected tab is remembered across launches now
            // (`NotchViewModel.selectedTab`), and this fired on the first poll
            // after launch — so the restored tab was overwritten with Musik
            // before it was ever seen, and every track change dragged you back
            // there. Which tab you are on is your choice, not playback's.
            syncSpectrum()
            // If the tap suspended itself after silence, a player flipping to
            // "playing" is the fastest resume signal there is — don't wait
            // for the probe.
            if playing { spectrum.pokeResume() }
        }
        .onChange(of: nowPlaying.screensAwake) { _, _ in syncSpectrum() }
    }

    // MARK: The wave that survives the morph

    /// Whether the spectrum is currently drawn as one persistent object that
    /// travels between the pill and the page.
    ///
    /// Only when the pill is *nothing but* the wave: with a timer readout or a
    /// shelf badge beside it the run is no longer centred in the capsule, and
    /// an overlay would have to re-derive an offset the `HStack` already owns.
    /// Those cases keep the plain crossfade, which is correct if less pretty.
    /// Only at the top border, and that is the whole of the reason: every
    /// number behind the flight — `pillWaveCentreY`, `pageWaveCentreY`, the
    /// scale between them — is measured from an island hanging off the top
    /// edge. The other three borders mirror or transpose that, and a run that
    /// travels to the wrong place is worse than one that simply crosses over.
    /// So they take the plain crossfade, which is the same fallback a timer
    /// readout or a shelf badge in the pill already takes.
    private var morphingWaveActive: Bool {
        settings.pillSpectrumOnly && hasAudioHero
            && pomodoro.pillText == nil && shelf.items.isEmpty
            && dock == .top
    }

    /// Whether a live activity (volume/brightness HUD, audio route, battery)
    /// has taken the collapsed pill over. It replaces the pill's usual content
    /// and narrows the capsule to its own width — see `islandWidth`.
    private var activityOwnsPill: Bool {
        viewModel.islandState == .collapsed && activities.current != nil
    }

    /// Whether the travelling wave is mounted at all.
    ///
    /// It stays mounted across the whole pill↔page journey, which is the point:
    /// giving it up when the pages mount means the spectrum page needs a second
    /// wave of its own, and that means a handover — which can only ever be as
    /// invisible as the two independently mounted views' poses happen to match.
    /// They don't. So there is nothing to hand over to.
    ///
    /// It is given up only where it has nowhere to be. An island resting open on
    /// some other tab has no spectrum in it at all: the run belongs to the
    /// spectrum page, which is off past the clip. Keeping it mounted there meant
    /// the island opening on, say, Timer had to fling the wave three page widths
    /// sideways to get it out of sight — a fast flick across an otherwise empty
    /// island, every single time you hovered the notch.
    ///
    /// Two more states where something else owns the pixels. The fullscreen
    /// takeover covers the island completely and has a wave of its own, so this
    /// one should not keep redrawing 30 times a second underneath it. A live
    /// activity takes over the collapsed pill the same way the pill hero does —
    /// but the hero is *content*, which the activity replaces, while this wave is
    /// an overlay that no content swap can reach: left mounted, it drew straight
    /// through the volume HUD's bar.
    private var morphingWaveVisible: Bool {
        morphingWaveActive && !fullscreen.isPresented && !activityOwnsPill
            && (waveIsOnPage || viewModel.islandState != .expanded)
    }

    /// Whether the wave currently belongs on the spectrum page rather than in
    /// the pill's band. The travel between the two poses *is* the morph.
    private var waveIsOnPage: Bool {
        viewModel.islandState == .expanded && viewModel.selectedTab == .spectrum
    }

    /// How the wave leaves when it is no longer the island's business.
    ///
    /// Sideways when the carousel is what took it away, because then it is
    /// standing in for a page that is itself sliding out: the spectrum page
    /// lives in the carousel, this run is drawn above it, and a run that stayed
    /// put would smear over whichever page slid in underneath. It travels
    /// exactly the distance the page does — one page width per tab of
    /// separation, the same arithmetic `ExpandedView` applies to the carousel —
    /// and the island's own clip swallows it a page width in.
    ///
    /// A dissolve everywhere else, and *everywhere else is the common case*:
    /// opening or closing the island is not carousel motion. It used to be
    /// treated as though it were, which is how hovering the notch on any tab but
    /// the spectrum flung the wave across the island the instant it landed open.
    ///
    /// `chromeRevealed` is the tell: a carousel can only have moved if there was
    /// a dressed, open island to move it in. It is still false while the island
    /// is landing — both on the staged walk and on the capture hotkey's jump
    /// straight to `.expanded`, which is the same flick in a hurry. And a zero
    /// shift means the tab did not change at all (the run gave up for some other
    /// reason — the music stopped, a file landed on the shelf), so there is
    /// nothing to slide.
    private var waveExitTransition: AnyTransition {
        let shift = waveCarouselShift
        guard viewModel.chromeRevealed, viewModel.islandState == .expanded, shift != 0 else { return .opacity }
        return .offset(x: shift)
    }

    /// How far the spectrum page has slid out of the island, and with it the run
    /// that stands in for it. Zero on the spectrum page itself.
    private var waveCarouselShift: CGFloat {
        guard viewModel.islandState == .expanded else { return 0 }
        let tabs = NotchViewModel.Tab.allCases
        guard let spectrumIndex = tabs.firstIndex(of: .spectrum),
              let currentIndex = tabs.firstIndex(of: viewModel.selectedTab) else { return 0 }
        return CGFloat(spectrumIndex - currentIndex) * NotchLayout.expandedPageSize.width
    }

    /// The bar count the run holds at every size.
    ///
    /// The pill's, everywhere: a count that changed as the wave travelled would
    /// re-bucket the spectrum on the very frames the eye is following, so the
    /// morph is purely geometric — the same bars, further apart and taller.
    private var pageWaveBarCount: Int { pillWaveGeometry.barCount }

    private var pillWaveGeometry: NotchLayout.PillSpectrumGeometry {
        NotchLayout.pillSpectrumGeometry(forWidth: settings.pillSpectrumWidth)
    }

    /// The one spectrum in the island, at whichever size and place the current
    /// state calls for.
    ///
    /// Everything about it is a *transform* of a single, never-remounted run:
    /// the canvas is always built at the page's geometry, and the pill is that
    /// same run scaled down. Nothing here redraws at a new size — the canvas's
    /// bar width, spacing and height are draw parameters, not animatable
    /// attributes, so animating them moves nothing while the bars snap. Scale
    /// and offset are the interpolation, which is why one view can cover the
    /// whole journey.
    private var morphingWave: some View {
        let wave = NotchLayout.spectrumPageWaveGeometry(barCount: pageWaveBarCount)
        let onPage = waveIsOnPage
        let tints = waveTints
        return LiveWaveBarsView(
            levels: spectrum.bands,
            isLive: spectrum.isLive,
            isActive: nowPlaying.screensAwake,
            tint: tints.primary,
            coverBars: tints.coverBars,
            count: wave.barCount,
            maxHeight: wave.waveHeight,
            barWidth: wave.barWidth,
            spacing: wave.spacing,
            morphScale: onPage ? 1 : NotchLayout.pillToPageWaveScale
        )
        // Page-sized frame at both ends, even while the run is drawn small
        // inside it: this is an overlay, so the frame costs no layout, and
        // `scaleEffect` scales about the frame's centre — so holding the frame
        // still is what keeps the shrunken run centred on the pill.
        .frame(width: wave.runWidth, height: wave.frameHeight)
        .offset(y: (onPage ? NotchLayout.pageWaveCentreY : NotchLayout.pillWaveCentreY) - wave.frameHeight / 2)
        .animation(NotchLayout.islandMorphAnimation, value: onPage)
        .allowsHitTesting(false)
    }

    private var island: some View {
        let cornerRadius = viewModel.isExpanded ? NotchLayout.expandedCornerRadius : viewModel.collapsedHeight / 2
        let shape = IslandShape(cornerRadius: cornerRadius)
        // The dark silhouette leads; content is clipped to the same rounded rect
        // so it can't float outside the shape while it resizes. The highlight rim
        // and shadow stay outside the clip.
        //
        // The explicit `.frame` before the clip is load-bearing: mid-morph the
        // content lays out larger than the animated island, and `clipShape` clips
        // to the bounds of the view it's attached to. Without the frame those
        // bounds are the (full-size) content, so nothing gets clipped and the
        // content floats over the wallpaper without black behind it.
        // The island's chrome — black fill, drop shadow, hairline rim — is
        // flattened into one GPU-composited layer. Rendered plainly, the
        // shadow's gaussian blur and the rim's gradient are rasterized by
        // CoreGraphics on the main thread for *every* frame of the morph
        // (and, before the shadow was decoupled from the content, for every
        // 30 Hz spectrum tick too) — `sample` showed exactly this shading
        // work under the expand jank. The symmetric padding gives the
        // flattened canvas room for the blur; the content stays outside the
        // group, because flattening kills AppKit-backed subviews (the
        // capture field).
        let chrome = ZStack {
            shape
                .fill(NotchLayout.islandFill)
                .shadow(
                    color: .black.opacity(viewModel.isExpanded ? NotchLayout.islandShadowOpacityExpanded : NotchLayout.islandShadowOpacityCollapsed),
                    radius: NotchLayout.islandShadowRadius,
                    y: NotchLayout.islandShadowYOffset
                )
            // Hairline rim, brightest along the top edge: separates the
            // near-black island from a dark menu bar / wallpaper.
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(NotchLayout.islandStrokeTopOpacity),
                        .white.opacity(NotchLayout.islandStrokeBottomOpacity),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: NotchLayout.islandStrokeWidth
            )
        }
        .padding(40)
        .drawingGroup()
        .padding(-40)

        let size = islandSize
        return chrome
            .overlay(
                ZStack(alignment: borderAlignment) {
                    content
                    // The spectrum lives *above* the island's content rather
                    // than inside it, so that opening the island moves one wave
                    // instead of dissolving the pill's into the page's. Nothing
                    // else can do that: the pill and the page are different
                    // subtrees mounted at different moments, so any wave owned
                    // by either of them has to fade when its owner does.
                    // Fades rather than cuts: an activity arriving (the volume
                    // HUD is the common one) rides the island morph, and the
                    // wave should leave with it instead of blinking out a
                    // frame early. Arrivals always dissolve; only departures get
                    // a say in how they go (see `waveExitTransition`).
                    if morphingWaveVisible {
                        morphingWave.transition(.asymmetric(insertion: .opacity, removal: waveExitTransition))
                    }
                }
                .frame(width: size.width, height: size.height, alignment: borderAlignment)
                .clipShape(shape)
            )
            .frame(width: size.width, height: size.height)
            .offset(x: islandXOffset)
            // Settings changes alter the pill's width formula outside the
            // staged walk's withAnimation calls; morph instead of snapping.
            .animation(NotchLayout.islandMorphAnimation, value: settings.pillSpectrumOnly)
            .animation(NotchLayout.islandMorphAnimation, value: settings.pillSpectrumWidth)
            // Timer start/stop and audio start/stop change width *and* offset
            // at rest, outside the walk's withAnimation calls; slide, don't snap.
            .animation(NotchLayout.islandMorphAnimation, value: pomodoro.pillText != nil)
            .animation(NotchLayout.islandMorphAnimation, value: hasAudioHero)
    }

    @ViewBuilder private var content: some View {
        let state = viewModel.islandState
        // When music plays or a focus timer is active, the collapse morphs
        // toward the pill content (cover + live spectrum and/or timer readout)
        // rather than the selected tab's icon+label — uniformly, whichever tab
        // you close from. So from the `.solo` stage on the pill hero stands in
        // for the tab bar and just shrinks into place; this dissolves the
        // "close Capture while music runs" dilemma, because the collapse
        // target depends on the pill content, not on the tab.
        let heroContent = hasAudioHero || pomodoro.pillText != nil
        // `.band` is included, not just `.solo`/`.condensing`: at that stage the
        // island has already shrunk to pill height while the tab bar is still
        // showing *every* tab and its label — so the hero (the wave) and those
        // labels occupied the same band and drew straight through each other on
        // every collapse. With the hero standing in from `.band` on, the tab bar
        // is gone by the time the island is pill-sized. On the way up it means
        // the tab bar appears only once the island is actually open — with
        // audio there is no glyph to walk out to its slot, because the pill's
        // content is the wave, so the row simply crosses in.
        let pillHero = heroContent && (state == .band || state == .solo || state == .condensing)
        let showsExpanded = state != .collapsed && !pillHero
        // Hero content → the tab bar and the pill hero are *different* content,
        // so cross-dissolve them. Otherwise the condensed icon and the pill
        // glyph are identical, so keep the hold-opaque handover (no dip).
        let handover: AnyTransition = heroContent ? .heroCrossfade : .iconHandover

        // Two explicit layers so the collapsed pill is *always* on top of the
        // outgoing tab bar during the handover — both pinned to the border, so
        // the handover happens in place on every one of them.
        ZStack(alignment: borderAlignment) {
            if showsExpanded {
                // Expanded through condensing: the tab bar is one persistent
                // view that sheds its parts itself (pages, then unselected
                // tabs, then labels), so nothing ever re-appears. By the time
                // it unmounts only the selected icon is left — pixel-identical
                // to the pill icon replacing it (idle case).
                ExpandedView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, pomodoro: pomodoro, capture: capture, spectrum: spectrum, spectrumWaveDrawnByOverlay: morphingWaveActive, spectrumWaveBarCount: morphingWaveActive ? pageWaveBarCount : nil)
                    .transition(handover)
            }
            if state == .collapsed || pillHero {
                if state == .collapsed, let activity = activities.current {
                    ActivityCompactView(activity: activity, dock: dock)
                        .foregroundStyle(.white)
                        .transition(.notchContent)
                } else {
                    // The pill hero: renders continuously across solo → condensing
                    // → collapsed when playing (one persistent view, so only the
                    // capsule shrinks around it — no swap), or just at collapsed
                    // when idle.
                    CollapsedView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, pomodoro: pomodoro, spectrum: spectrum, hasAudioHero: hasAudioHero, waveDrawnByOverlay: morphingWaveActive)
                        .foregroundStyle(.white)
                        .transition(handover)
                }
            }
        }
    }
}
