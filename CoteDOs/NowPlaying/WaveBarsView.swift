import AppKit
import SwiftUI

/// One bar's colours, resolved once per view update rather than per bar per
/// frame. Everything in here is independent of the bar's current level, so the
/// only colour work left in the draw path is the tip whitening — and `HSB`
/// does that as arithmetic, with no trip through NSColor/ColorSync.
struct BarInk {
    /// The bar's body colour for this style.
    let base: Color
    let baseHSB: HSB
    /// What the bar's top-to-bottom gradient ends on.
    let foot: Color
    /// The foot decomposed, so `WaveCanvas` can pull it back toward the base on
    /// bars far taller than the ones the drain was measured on.
    let footHSB: HSB

    /// Depth, in the direction Apple's own bars run. A bar on a real iPhone's
    /// Dynamic Island travels from S 0.59 / B 0.60 at its tip to S 0.32 /
    /// B 0.64 at its base (measured off screenshots of the now-playing
    /// island): the colour *drains* toward the foot and lifts a touch in
    /// brightness, rather than darkening. Push it the other way — full colour at
    /// the tip, 72% brightness at the base — and the bars read as standing on the
    /// black instead of sunk into it.
    static let footSaturation = 0.55   // 0.32 / 0.59
    static let footBrightness = 1.07   // 0.64 / 0.60

    init(_ color: Color) {
        let hsb = HSB(color)
        let drained = hsb.scaledHSB(saturation: Self.footSaturation, brightness: Self.footBrightness)
        self.base = color
        self.baseHSB = hsb
        self.foot = drained.color
        self.footHSB = drained
    }

    /// The quantised cover column, whose shading was worked out once when the
    /// palette was built (see `CoverBarPalette.Bar`).
    init(coverBar: CoverBarPalette.Bar) {
        self.base = coverBar.top
        self.baseHSB = coverBar.topHSB
        self.foot = coverBar.foot
        self.footHSB = HSB(coverBar.foot)
    }
}

/// A run of bar levels that SwiftUI can interpolate.
///
/// A `Canvas` is not animated by putting `.animation` on it: the drawing
/// closure only runs when the view is re-evaluated, so the *view* has to be
/// `Animatable` and feed the interpolated value back into the drawing. This is
/// that value — the whole run as one animatable quantity.
struct BarLevels: VectorArithmetic {
    var values: [CGFloat]

    static var zero: BarLevels { BarLevels(values: []) }

    static func + (lhs: BarLevels, rhs: BarLevels) -> BarLevels { combine(lhs, rhs, +) }
    static func - (lhs: BarLevels, rhs: BarLevels) -> BarLevels { combine(lhs, rhs, -) }

    /// Runs of different length only meet when the bar count itself changes
    /// (the pill's slider). Pad rather than truncate, so the added bars grow
    /// from nothing instead of the whole wave snapping to a new shape.
    private static func combine(_ lhs: BarLevels, _ rhs: BarLevels, _ op: (CGFloat, CGFloat) -> CGFloat) -> BarLevels {
        let n = max(lhs.values.count, rhs.values.count)
        return BarLevels(values: (0..<n).map { i in
            op(i < lhs.values.count ? lhs.values[i] : 0, i < rhs.values.count ? rhs.values[i] : 0)
        })
    }

    mutating func scale(by rhs: Double) {
        for i in values.indices { values[i] *= CGFloat(rhs) }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + Double($1 * $1) }
    }
}

/// The wave's *dimensions* as one interpolatable quantity, so a change of size
/// morphs instead of cutting.
///
/// Animatable, so the run's thickness, gaps and vertical range interpolate
/// rather than jumping in a single frame. Plain `let`s on `WaveCanvas` are enough
/// while every wave has a fixed size, and stop being enough the moment the pill
/// and the spectrum page derive their geometry from one rule: they are the same
/// wave at two scales, so growing from one into the other is a pure
/// interpolation of this struct.
struct WaveMetrics: VectorArithmetic {
    var barWidth: CGFloat
    var spacing: CGFloat
    var maxHeight: CGFloat
    var floorHeight: CGFloat

    static var zero: WaveMetrics { WaveMetrics(barWidth: 0, spacing: 0, maxHeight: 0, floorHeight: 0) }

    static func + (lhs: WaveMetrics, rhs: WaveMetrics) -> WaveMetrics { combine(lhs, rhs, +) }
    static func - (lhs: WaveMetrics, rhs: WaveMetrics) -> WaveMetrics { combine(lhs, rhs, -) }

    private static func combine(_ lhs: WaveMetrics, _ rhs: WaveMetrics,
                                _ op: (CGFloat, CGFloat) -> CGFloat) -> WaveMetrics {
        WaveMetrics(barWidth: op(lhs.barWidth, rhs.barWidth),
                    spacing: op(lhs.spacing, rhs.spacing),
                    maxHeight: op(lhs.maxHeight, rhs.maxHeight),
                    floorHeight: op(lhs.floorHeight, rhs.floorHeight))
    }

    mutating func scale(by rhs: Double) {
        let f = CGFloat(rhs)
        barWidth *= f
        spacing *= f
        maxHeight *= f
        floorHeight *= f
    }

    var magnitudeSquared: Double {
        Double(barWidth * barWidth + spacing * spacing + maxHeight * maxHeight + floorHeight * floorHeight)
    }
}

/// The whole wave, drawn in a single pass.
///
/// A `Canvas`, not an `HStack` of 32 `Capsule`s, and the reason is measured: the
/// view-per-bar version cost ~52% of a core for a thumbnail-sized strip of
/// rounded rects. Never the pixels — every animated frame re-evaluated and
/// re-laid-out 32 views' worth of view graph, 60 times a second. Behind a
/// `Canvas` there is no per-bar identity and no layout (one closure, `count`
/// rounded rects), so a frame costs about what it looks like it should, and the
/// bars can keep easing between spectrum updates on battery as well as on wall
/// power.
struct WaveCanvas: View, Animatable {
    /// Per-bar magnitude (0…1). Interpolated by SwiftUI; drives height, glow
    /// intensity and the white-hot tip alike.
    var levels: BarLevels
    /// Per-bar colours. Not animatable — a cover change swaps these outright
    /// rather than crossfading, which is the one thing lost by leaving the
    /// view-per-bar layout behind.
    let inks: [BarInk]
    /// The run's dimensions. Deliberately *not* part of `animatableData`: the
    /// levels re-animate 30×/s with their own 0.09 s ease, and when both shared
    /// one animatable value that ease restarted the size interpolation on every
    /// spectrum update — collapsing a 0.4 s morph into 0.09 s (invisible) and
    /// making the motion itself jittery. Resizing is animated one level up
    /// instead, as a transform (see `WaveBarsView.morphScale`).
    let metrics: WaveMetrics
    /// Which way the run reads. `.horizontal` is the wave everywhere it has
    /// ever been: bars side by side, growing up and down from a centre line.
    /// `.vertical` turns that a quarter turn for an island standing on a side
    /// border — bars stacked down the run, growing left and right. A transposed
    /// draw rather than a rotated view: rotating would carry the gradient's
    /// measured top-to-foot drain around with it, and that drain is depth, not
    /// direction — it must keep pointing away from the bar's tip.
    var axis: Axis = .horizontal

    var animatableData: BarLevels {
        get { levels }
        set { levels = newValue }
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let total = min(levels.values.count, inks.count)
            guard total > 0 else { return }
            let barWidth = max(0, metrics.barWidth)
            let spacing = max(0, metrics.spacing)
            let runLength = CGFloat(total) * barWidth + CGFloat(total - 1) * spacing
            // `along` walks the run; `length` is the one bar's deflection. The
            // two map onto x/y one way or the other — everything else about a
            // bar is the same in both.
            let vertical = axis == .vertical
            var along = ((vertical ? size.height : size.width) - runLength) / 2
            for i in 0..<total {
                let level = max(0, min(1, levels.values[i]))
                let length = max(metrics.floorHeight, metrics.maxHeight * level * Self.envelope(at: i, total: total))
                let rect = vertical
                    ? CGRect(x: (size.width - length) / 2, y: along, width: length, height: barWidth)
                    : CGRect(x: along, y: (size.height - length) / 2, width: barWidth, height: length)
                draw(&context, rect: rect, vertical: vertical, ink: inks[i])
                along += barWidth + spacing
            }
        }
    }

    /// Height envelope across the run: full in the middle, tapering toward
    /// both ends, so the wave has a *shape* — a crest that swells and falls —
    /// instead of a rectangle of equally tall bars.
    ///
    /// The taper depth depends on the bar count. The Dynamic Island's 6-bar
    /// wave measures 2.0/4.3/12.7/12.0/7.3/2.0 pt — its edge bars sit at ~16%
    /// of the peak, not 45%. A 0.45 floor at 6 bars is what made the pill read
    /// as a flat block; at 16+ bars the same deep taper would duck a third of
    /// the run, so the floor eases back up to 0.45 there. The exponent
    /// steepens for small counts for the same reason: with 6 bars every bar
    /// *is* the curve.
    /// At wide counts the envelope all but disappears (floor 0.75): with 32
    /// bars there is no bucketing, so an imposed crest was the one thing
    /// still masking the music — the stage view proved the same data reads
    /// far livelier without it. Small counts keep the deep Apple-style dip.
    static func envelope(at index: Int, total: Int) -> CGFloat {
        guard total > 1 else { return 1 }
        let spread = min(1, max(0, CGFloat(total - 6) / 10))   // 0 at ≤6 bars, 1 at ≥16
        let floor = 0.16 + (0.75 - 0.16) * spread
        let exponent = 0.8 - 0.3 * spread
        let t = CGFloat(index) / CGFloat(total - 1)
        return floor + (1 - floor) * pow(sin(.pi * t), exponent)
    }

    /// Tallest bar the measured foot drain applies to in full.
    ///
    /// The drain is a *proportional* gradient — top colour to a desaturated,
    /// slightly brighter foot — measured off an iPhone's island, whose bars top
    /// out around 13 pt. Spread over the spectrum page's ~140 pt bars the drained
    /// end owns most of the shape, and a loud passage turns the whole wave pale;
    /// at fullscreen it went white. The taller the bar, the less of it should be
    /// drain, which is what dividing by its height does.
    ///
    /// 40 rather than 130 so the pull-back starts well before the page rather
    /// than only past it. Everything the collapsed pill draws is under 40 pt, so
    /// the pill keeps the full measured drain and is pixel-identical to before —
    /// which matters, because that is the wave tuned against the real hardware.
    private static let fullDrainBarHeight: CGFloat = 40

    private static let minimumDrain: CGFloat = 0.35

    /// The colour a bar's gradient ends on, held back on bars taller than the
    /// drain was measured for.
    private static func foot(of ink: BarInk, barHeight: CGFloat) -> Color {
        guard barHeight > fullDrainBarHeight else { return ink.foot }
        let drain = max(minimumDrain, fullDrainBarHeight / barHeight)
        return ink.baseHSB.mixed(to: ink.footHSB, t: Double(drain)).color
    }

    private func draw(_ context: inout GraphicsContext, rect: CGRect, vertical: Bool, ink: BarInk) {
        // Round on the bar's thin side, whichever that is — a vertical run's
        // bars are wide and short, and halving their width would swallow them.
        let capsule = Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)

        // No halo. Every bar used to throw its own light, scaled by its level,
        // on the theory that it made the wave read as alive rather than printed
        // on. Measured against the reference it does the opposite: the island's
        // bars have no glow at all, and ours turned the pure black around the
        // run milky grey, which is most of what made the colours look dirty.
        //
        // A bar's *colour* does not change with its level either. Driving a
        // peaking tip 60% toward white ("incandescence") is the obvious thing to
        // try and it is wrong: the Dynamic Island's bars hold their colour and
        // only their height moves.
        // The drain runs the bar's *length* — the direction it deflects in —
        // so on a vertical run it crosses the bar left to right, and it is the
        // length (not a fixed axis) that decides how far the foot is held back.
        let barLength = vertical ? rect.width : rect.height
        context.fill(
            capsule,
            with: .linearGradient(
                Gradient(colors: [ink.base, Self.foot(of: ink, barHeight: barLength)]),
                startPoint: vertical ? CGPoint(x: rect.minX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.minY),
                endPoint: vertical ? CGPoint(x: rect.maxX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
    }
}

/// Frequency bars for the now-playing wave. When `bands` carries real spectrum
/// data (from `SpectrumAnalyzer`) the bars reflect the song's actual frequencies;
/// otherwise they fall back to a procedural animation. Tinted to the cover's
/// accent colour when one is available, else white — the same answer
/// `ArtworkColor` gives for a sleeve with no real colour in it.
struct WaveBarsView: View {
    var isActive: Bool
    var tint: Color?
    /// Quantised cover colours (see `ArtworkColor.fetchBarPalette`): one colour
    /// per bar, taken from the slice of cover that bar sits over. nil → the
    /// whole run draws in `tint`.
    var coverBars: CoverBarPalette? = nil
    /// Live per-band magnitudes (0…1). nil/empty → procedural fallback.
    var bands: [CGFloat]? = nil
    var count: Int = 4
    var maxHeight: CGFloat = 26
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    /// Size the run is drawn at relative to its own geometry, for the pill⇄page
    /// morph: the caller holds this away from 1 for the first frame after the
    /// wave appears and the spring carries it home. 1 means no morph is running,
    /// which is every wave that isn't mid-transition.
    var morphScale: CGFloat = 1
    /// The spring `morphScale` rides. Must be whatever the caller animates the
    /// run's *offset* with, or the wave arrives at its destination before (or
    /// after) it finishes growing — the two halves of one movement.
    var morphAnimation: Animation = NotchLayout.islandMorphAnimation
    /// Which way the run reads — see `WaveCanvas.axis`. `maxHeight`, `barWidth`
    /// and the rest keep their names in both: they are the bar's deflection and
    /// its thickness, whichever screen axis those land on.
    var axis: Axis = .horizontal
    /// Decides whether the bars ease between updates — see the `body` comment.
    @ObservedObject private var power = PowerSource.shared

    // iOS's Dynamic Island wave bars are flat, fully-opaque colour top to
    // bottom — no fade. One solid colour per bar here too: fading each down to
    // 55% opacity, at how thin these bars are, makes the colour nearly
    // impossible to see at all.
    /// The whole run's colours: one per bar, taken from the slice of cover that
    /// bar sits over (see `ArtworkColor.fetchBarPalette`).
    ///
    /// Built once per update rather than inside the draw call. Per-bar-per-frame
    /// costs four ColorSync round-trips — ~2900/s for the 32-bar pill at 30 fps,
    /// and the single biggest item in a `sample` of the idling app.
    private func palette(total: Int) -> [BarInk] {
        // No cover, or a sleeve whose colour extraction found no real hue — one
        // toned-down accent across the run, falling back to `ArtworkColor`'s own
        // "no real colour here" answer. That answer is white, and it goes
        // through `stageVivid` like every other tint: a run of full-brightness
        // white bars beside any cover's would be the brightest thing the wave
        // ever draws, which is backwards for the case with the least to say.
        let fallback = BarInk(Color.stageVivid(tint ?? .white))
        guard let coverBars else { return Array(repeating: fallback, count: total) }
        return (0..<total).map { index in
            coverBars.bar(forBarAt: index, total: total).map(BarInk.init(coverBar:)) ?? fallback
        }
    }

    /// iOS's spectrum bars never fully bottom out — even a silent band keeps a
    /// visible sliver. The hard floor sits a touch above where it reads flat, so
    /// the quietest bar still reads as "there".
    /// Proportional, with only a hairline clamp: a flat 4 pt floor on the pill's
    /// short bars swallows 22% of the run's height —
    /// the stage view's floor is 14% and its extra headroom is exactly what
    /// makes the same data read livelier there.
    private var floorHeight: CGFloat { max(2, maxHeight * 0.14) }

    /// Fit the source bands to `count` bars: pass through when they match, else
    /// group into `count` buckets. Each bucket blends its max with its mean:
    /// pure max compressed the wave's dynamics — with 32 bands folded onto 6
    /// bars almost every bucket contains *some* loud band, so all bars sat
    /// high (band span 0.66 collapsed to bar span 0.19) and the pill read as a
    /// flat block. The mean half restores the spread; the max half keeps the
    /// punch of a transient that only lives in one band.
    private func fitted(_ source: [CGFloat]) -> [CGFloat] {
        guard count > 0, !source.isEmpty else { return source }
        if source.count == count { return source }
        return (0..<count).map { i in
            let lo = i * source.count / count
            let hi = max(lo + 1, (i + 1) * source.count / count)
            let bucket = source[lo..<min(hi, source.count)]
            let peak = bucket.max() ?? 0
            let mean = bucket.reduce(0, +) / CGFloat(bucket.count)
            return (peak + mean) / 2
        }
    }

    private var metrics: WaveMetrics {
        WaveMetrics(barWidth: barWidth, spacing: spacing, maxHeight: maxHeight, floorHeight: floorHeight)
    }

    private func wave(levels: [CGFloat], inks: [BarInk]) -> WaveCanvas {
        WaveCanvas(levels: BarLevels(values: levels), inks: inks, metrics: metrics, axis: axis)
    }

    var body: some View {
        // The morph transform sits *outside* the live/procedural branch, and has
        // to: `morphScale` is how a run drawn at page geometry becomes the pill's,
        // so a branch that skips it draws the page's wave at full size inside the
        // capsule — the pill⇄page scale is under 0.5 (see `WaveHandoverTests`), so
        // that is the whole spectrum page crammed into the pill and clipped by it.
        // Which is exactly what the fallback did: waking the Mac with Spotify
        // reporting playback from another device (Connect) leaves the tap with no
        // signal, the run falls back to the procedural loop, and the pill filled
        // with a wave twice the size it had room for.
        run
            .scaleEffect(morphScale)
            .animation(morphAnimation, value: morphScale)
    }

    @ViewBuilder
    private var run: some View {
        if let bands, !bands.isEmpty {
            // Real spectrum: bar height follows each band, eased between
            // updates so the wave flows instead of stepping.
            //
            // This ease is the most expensive thing in the app: a new target
            // arrives before the previous one finishes, so an animation is
            // permanently in flight, and that makes SwiftUI re-evaluate its
            // animated attributes on every 60 Hz display refresh however
            // rarely the bands change. The `Canvas` rewrite (see `WaveCanvas`)
            // made each of those frames much cheaper — but even so the ease
            // measured 25–28% of a core against 9–11% without it, so on
            // battery it goes away and the bars step straight to each
            // published level. `PowerSource` decides; the trade is deliberate.
            //
            // Note what is *not* animated any more: the bar colours. They used
            // to crossfade over 0.4s when the cover changed; a canvas can't
            // interpolate them, so a new palette now takes effect at once.
            let values = fitted(bands)
            // The pill⇄page morph is applied above, as a transform rather than a
            // redraw: the two ends are the same wave at two scales, so scaling
            // *is* the interpolation — and unlike animating the canvas's
            // geometry it cannot be restarted by this levels ease, which is what
            // kept the morph from ever being visible.
            wave(levels: values, inks: palette(total: values.count))
                .frame(maxWidth: axis == .vertical ? .infinity : nil,
                       maxHeight: axis == .horizontal ? .infinity : nil,
                       alignment: .center)
                .animation(power.isOnBattery ? nil : .easeOut(duration: 0.09), value: values)
        } else {
            // Hoisted out of the timeline closure on purpose: the colours don't
            // depend on the clock, so they're resolved once per update instead
            // of on every one of the 30 ticks a second.
            let inks = palette(total: count)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                // The timeline already supplies a new value per frame, so this
                // branch needs no animation of its own.
                wave(levels: (0..<count).map { proceduralLevel(index: $0, time: time) }, inks: inks)
                    .frame(maxWidth: axis == .vertical ? .infinity : nil,
                       maxHeight: axis == .horizontal ? .infinity : nil,
                       alignment: .center)
            }
        }
    }

    /// The procedural fallback's level for one bar (0…1) — `WaveCanvas` turns
    /// it into a height the same way it does a real band's.
    private func proceduralLevel(index: Int, time: Double) -> CGFloat {
        guard isActive, maxHeight > 0 else { return floorHeight / max(maxHeight, 1) }
        let phase = Double(index) * 0.7
        return CGFloat(0.35 + 0.65 * abs(sin(time * 4 + phase)))
    }
}

// Per-bar shading lives on `HSB`, not on `Color`: a helper taking a `Color`
// decomposes it on every call, which is a ColorSync round-trip, and the wave
// would call it per bar per frame. `HSB` operates on components resolved once
// per palette — see `WaveBarsView.BarInk`.
extension Color {
    private var hsb: HSB { HSB(self) }

    /// The treatment a colour gets *only when painted as a spectrum bar* — here,
    /// the whole-run fallback for a track with no cover palette. The accent
    /// stays as it is everywhere else (title glow, placeholder tint); a bar
    /// carries the sleeve's hue at the wave's own weight.
    ///
    /// Same band `ArtworkColor.barVibrant` maps the cover's palette into, so the
    /// fallback and a real palette read as the same material. Measured off three
    /// iPhone now-playing waveforms: whatever the sleeve, Apple's bars land at
    /// S 0.08–0.38 and B 0.43–0.67. Pushing the other way is where a
    /// neon-looking wave comes from — our own cover style used to sit at
    /// S 0.63–0.81 by boosting instead of toning down.
    private static let barSaturation: ClosedRange<CGFloat> = 0.10...0.38
    private static let barBrightness: ClosedRange<CGFloat> = 0.46...0.67

    static func stageVivid(_ color: Color) -> Color {
        let c = color.hsb
        // A genuinely neutral colour (white fallback, B/W cover) must stay
        // neutral — saturating it would invent a hue that isn't there. It still
        // has to come down into the band, or it draws as a white bar.
        guard c.s > 0.02 else {
            return Color(hue: 0, saturation: 0, brightness: min(c.b, barBrightness.upperBound))
        }
        return Color(
            hue: c.h,
            saturation: min(max(c.s, barSaturation.lowerBound), barSaturation.upperBound),
            brightness: min(max(c.b, barBrightness.lowerBound), barBrightness.upperBound)
        )
    }
}
