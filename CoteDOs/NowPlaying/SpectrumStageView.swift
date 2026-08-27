import SwiftUI

/// The spectrum with nothing else on the page: bars sized from the space they
/// are given rather than from constants, so the same view works at pill size
/// and blown up to a whole screen.
///
/// This is the scalable form of the wave. `WaveBarsView` takes its geometry as
/// parameters and draws through a single `Canvas`, so the only thing standing
/// between the pill's 20 pt run and a screen-saver-sized one is deciding how
/// many bars to draw and how thick — which is what `NotchLayout.stageWaveGeometry`
/// does. Everything visual (colour derivation, the vertical gradient, the glow)
/// is shared, so the big version can't drift away from the small one.
struct SpectrumStageView: View {
    /// Live band levels, observed here and nowhere above, so a spectrum update
    /// redraws the bars and not the page around them (see `SpectrumBands`).
    @ObservedObject var levels: SpectrumBands
    var isLive: Bool
    var isActive: Bool
    var tint: Color?
    var coverBars: CoverBarPalette?
    /// Where this run comes from — the size and place it starts at, so it
    /// travels into position instead of appearing there. The pill for the
    /// island's page; the island's page for the fullscreen stage. nil means
    /// "just appear".
    ///
    /// Both numbers are worked out by the caller from `NotchLayout`, never from
    /// this view's own `GeometryReader`: the reader reports a zero size on its
    /// first pass, and a ratio taken from that put a nonsense scale on exactly
    /// the frame the animation had to start from.
    var morphOrigin: WaveMorphOrigin?
    /// Hold the run at this many bars instead of deriving a count from the
    /// available space. Used by the fullscreen stage so the wave that travels
    /// up from the island keeps its identity — a count that changes mid-flight
    /// re-buckets the spectrum on exactly the frames the eye is following.
    var fixedBarCount: Int?
    /// Whether the run has arrived. Owned by the caller, because a view cannot
    /// reliably animate its own arrival: a state change made while the view is
    /// still being installed is folded into the insertion and does not animate.
    var landed: Bool = true
    /// The spring the arrival rides. Defaults to the island's own morph, which
    /// is right for a run travelling inside it; the fullscreen takeover passes
    /// `NotchLayout.spectrumFullscreenMorphAnimation` because it covers several
    /// times the distance and needs longer to do it.
    var morphAnimation: Animation = NotchLayout.islandMorphAnimation
    /// Which way the run reads — see `WaveCanvas.axis`. The geometry rule is
    /// the same either way, so a vertical stage simply resolves it against the
    /// transposed field: bar thickness from the stage's *width*, and as many
    /// bars as fit its height.
    var axis: Axis = .horizontal

    private var origin: WaveMorphOrigin { landed ? .identity : (morphOrigin ?? .identity) }

    var body: some View {
        GeometryReader { geo in
            let field = axis == .horizontal
                ? geo.size
                : CGSize(width: geo.size.height, height: geo.size.width)
            let stage = NotchLayout.stageWaveGeometry(
                in: field, barCount: fixedBarCount,
                fieldAspect: axis == .horizontal
                    ? NotchLayout.pillSpectrumFieldAspect
                    : NotchLayout.portraitStageFieldAspect)
            WaveBarsView(
                isActive: isActive,
                tint: tint,
                coverBars: coverBars,
                bands: isLive ? levels.values : nil,
                count: stage.barCount,
                maxHeight: stage.waveHeight,
                barWidth: stage.barWidth,
                spacing: stage.spacing,
                morphScale: origin.scale,
                morphAnimation: morphAnimation,
                axis: axis
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .offset(y: origin.offsetY)
        .animation(morphAnimation, value: origin)
    }
}

/// The size and place a wave starts from when it morphs into position.
struct WaveMorphOrigin: Equatable {
    var scale: CGFloat
    var offsetY: CGFloat

    static let identity = WaveMorphOrigin(scale: 1, offsetY: 0)
}
