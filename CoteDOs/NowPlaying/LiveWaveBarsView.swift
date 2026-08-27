import SwiftUI

/// `WaveBarsView` fed from the live tap. It exists as a view of its own so the
/// band updates — 30 a second — invalidate the bars and nothing else: the
/// levels live on their own observable (`SpectrumBands`), and this is the only
/// place that observes it. Wrap the wave in this instead of reading
/// `spectrum.bands.values` from a parent, or the parent starts re-rendering at
/// the tap's rate again and takes the whole notch with it.
struct LiveWaveBarsView: View {
    @ObservedObject var levels: SpectrumBands
    /// False when the tap isn't running (no permission, macOS < 14.4, …) —
    /// the wave then falls back to its procedural animation.
    var isLive: Bool
    /// Additional gate for callers that must not show *someone else's* audio,
    /// e.g. the music tab while its own player is paused.
    var showsLiveBands: Bool = true

    var isActive: Bool
    var tint: Color?
    var coverBars: CoverBarPalette?
    var count: Int = 4
    var maxHeight: CGFloat = 26
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    /// See `WaveBarsView.morphScale`.
    var morphScale: CGFloat = 1
    /// See `WaveBarsView.morphAnimation`.
    var morphAnimation: Animation = NotchLayout.islandMorphAnimation
    /// See `WaveCanvas.axis`.
    var axis: Axis = .horizontal

    var body: some View {
        WaveBarsView(
            isActive: isActive,
            tint: tint,
            coverBars: coverBars,
            bands: (isLive && showsLiveBands) ? levels.values : nil,
            count: count,
            maxHeight: maxHeight,
            barWidth: barWidth,
            spacing: spacing,
            morphScale: morphScale,
            morphAnimation: morphAnimation,
            axis: axis
        )
    }
}
