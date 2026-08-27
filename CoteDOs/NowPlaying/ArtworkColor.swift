import AppKit
import CoreImage
import SwiftUI

/// Derives a single vibrant accent colour from album artwork — used to tint the
/// now-playing wave visualizer so it matches the cover — and the quantised
/// per-column palette the `.coverImage` bar style draws with.
///
/// A plain pixel average (`CIAreaAverage`) blends *all* regions of the cover
/// into one value, which reads as a muddy brown/olive whenever the artwork has
/// two or more distinct saturated regions (say, a red logo on a green
/// background) — averaging red and green lands roughly on brown/yellow, which
/// looks like neither. Instead this buckets pixels by hue and picks whichever
/// saturated hue actually dominates the cover, so a mostly-red-and-green image
/// comes out red or green (whichever has more weight) rather than their
/// blended midpoint.
///
/// A tiny splash of colour (a hand, a logo, a sliver of coloured spine on an
/// otherwise black-and-white cover) is deliberately *not* enough to win: the
/// winning hue bucket must account for a real share of the whole image
/// (`minimumDominantShare`). When nothing clears that bar — a genuinely
/// grayscale/monochrome cover — this returns white rather than an unrelated
/// default colour, since white is the neutral "no real colour here" answer.
enum ArtworkColor {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    private static var cache: [URL: ArtworkAccents] = [:]
    private static var iconCache: [String: Color] = [:]
    private static var barPaletteCache: [URL: CoverBarPalette] = [:]

    /// Loads `url` off the main thread and calls back on the main thread with
    /// the cover's accents, or nil if they couldn't be derived. Results are
    /// cached per URL.
    static func fetch(from url: URL, completion: @escaping (ArtworkAccents?) -> Void) {
        if let cached = cache[url] {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let result = data(for: url).flatMap(accents(from:))
            DispatchQueue.main.async {
                if let result { cache[url] = result }
                completion(result)
            }
        }
    }

    /// Same idea as `fetch(from:completion:)`, but for an in-memory app icon
    /// (the collapsed pill's generic-audio fallback, e.g. Safari) rather than a
    /// remote/file artwork URL — used to tint that wave the same way a track's
    /// cover tints it, instead of leaving it flat white. Cached by `cacheKey`
    /// (the source app's bundle ID) since an `NSImage` isn't itself hashable.
    static func fetch(from image: NSImage, cacheKey: String, completion: @escaping (Color?) -> Void) {
        if let cached = iconCache[cacheKey] {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let color = pngData(from: image).flatMap { accents(from: $0)?.primary }
            DispatchQueue.main.async {
                if let color { iconCache[cacheKey] = color }
                completion(color)
            }
        }
    }

    /// Quantised per-column cover colours for the `.coverImage` spectrum style.
    /// Results are cached per URL.
    static func fetchBarPalette(from url: URL, completion: @escaping (CoverBarPalette?) -> Void) {
        if let cached = barPaletteCache[url] {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let palette = data(for: url).flatMap(barPalette(from:))
            DispatchQueue.main.async {
                if let palette { barPaletteCache[url] = palette }
                completion(palette)
            }
        }
    }

    /// The most recently loaded cover, kept so the accents and the bar palette —
    /// two passes over the same artwork — don't download the JPEG twice. One
    /// entry is enough: only the current track's cover is ever analysed.
    private static var lastImageData: (url: URL, data: Data)?
    private static let imageDataLock = NSLock()

    private static func data(for url: URL) -> Data? {
        imageDataLock.lock()
        let cached = lastImageData
        imageDataLock.unlock()
        if let cached, cached.url == url { return cached.data }

        guard let data = try? Data(contentsOf: url) else { return nil }
        imageDataLock.lock()
        lastImageData = (url, data)
        imageDataLock.unlock()
        return data
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A winning hue bucket must contain at least this fraction of all sampled
    /// pixels to count as "dominant" — otherwise it's just a small coloured
    /// detail on an essentially monochrome cover, not a real accent.
    private static let minimumDominantShare: Double = 0.10

    /// One hue bucket's saturation-weighted average colour plus how much of the
    /// image it covers, as produced by `hueBuckets(from:)`.
    private struct HueBucket {
        var rgb: (r: CGFloat, g: CGFloat, b: CGFloat)
        var share: Double
    }

    /// What `hueBuckets(from:)` found: the hue buckets themselves plus how much
    /// of the cover carries no hue at all (the black/white/grey pixels the
    /// buckets deliberately ignore). The bar palette needs that neutral share —
    /// a cover that's half white lettering on red shouldn't have its white half
    /// snapped onto the red.
    private struct HueAnalysis {
        var buckets: [HueBucket]
        var neutralShare: Double
        /// Average brightness of those neutral pixels (0…1).
        var neutralLuma: CGFloat
    }

    /// Renders `data` into an RGBA8 grid of at most `side` × `side` pixels.
    private static func sample(_ data: Data, side: CGFloat) -> (bitmap: [UInt8], width: Int, height: Int)? {
        guard let image = CIImage(data: data) else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = side / max(extent.width, extent.height)
        guard let scaleFilter = CIFilter(name: "CILanczosScaleTransform", parameters: [
            kCIInputImageKey: image,
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0,
        ]), let scaled = scaleFilter.outputImage else { return nil }

        let width = Int(scaled.extent.width.rounded(.down))
        let height = Int(scaled.extent.height.rounded(.down))
        guard width > 0, height > 0 else { return nil }

        var bitmap = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            scaled, toBitmap: &bitmap, rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (bitmap, width, height)
    }

    /// Buckets the cover's pixels by hue (skipping washed-out
    /// near-gray/near-black/near-white ones, which carry no real colour
    /// information) and returns the non-empty buckets ordered by
    /// saturation-weighted mass — i.e. the hues that actually dominate the
    /// artwork, strongest first. nil only when the image couldn't be
    /// read/decoded at all.
    private static func hueBuckets(from data: Data) -> HueAnalysis? {
        guard let (bitmap, _, _) = sample(data, side: 32) else { return nil }

        let bucketCount = 24
        var bucketWeight = [CGFloat](repeating: 0, count: bucketCount)
        var bucketR = [CGFloat](repeating: 0, count: bucketCount)
        var bucketG = [CGFloat](repeating: 0, count: bucketCount)
        var bucketB = [CGFloat](repeating: 0, count: bucketCount)
        var bucketPixelCount = [Int](repeating: 0, count: bucketCount)
        var neutralPixelCount = 0
        var neutralLumaSum: CGFloat = 0
        // Counts only the pixels that actually carry an image. Covers are
        // opaque, so for them this ends up as `width * height` and nothing
        // changes — but an *app icon* (see the `NSImage` overload of `fetch`)
        // is a rounded shape on a transparent canvas, and roughly 45% of its
        // square is margin. `sample` renders premultiplied, so that margin
        // arrives as (0,0,0,0): pure black, which failed the `v > 0.05` guard
        // below and was counted as a *neutral* pixel with luma 0. That both
        // diluted every hue's share against a denominator it had no chance of
        // filling and inflated `neutralShare` past the neutral contest's
        // threshold — Apple Music's icon came out grey and Chrome's washed
        // out, purely from the empty corners of the canvas.
        var opaquePixelCount = 0

        for i in stride(from: 0, to: bitmap.count, by: 4) {
            // Kept high rather than at 0.5: above it the premultiplied colour
            // is within a couple of percent of the true one, so the antialiased
            // rim never has to be un-premultiplied to be read correctly.
            guard CGFloat(bitmap[i + 3]) / 255 > 0.9 else { continue }
            opaquePixelCount += 1
            let r = CGFloat(bitmap[i]) / 255
            let g = CGFloat(bitmap[i + 1]) / 255
            let b = CGFloat(bitmap[i + 2]) / 255
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            NSColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            // Skip only genuinely gray/black/white pixels: they don't belong to
            // any real hue and would otherwise dilute every bucket evenly. Kept
            // deliberately loose — the s*s weighting below already lets truly
            // pastel pixels fade out on their own; a strict cutoff here was
            // throwing out most of a typical (slightly muted, JPEG-compressed)
            // cover.
            guard s > 0.06, v > 0.05, v < 0.98 else {
                neutralPixelCount += 1
                neutralLumaSum += v
                continue
            }
            let bucket = min(bucketCount - 1, Int(h * CGFloat(bucketCount)))
            // s² alone let a large area of dark-but-saturated shadow/background
            // (a deep teal-black gradient, say) outvote a smaller, brighter,
            // obviously-the-accent region — dark colours can be just as
            // colorimetrically saturated as bright ones, but read as "shadow"
            // rather than "the cover's colour". The extra v² factor makes
            // brightness pull its own weight alongside saturation, so a bright
            // vivid patch reliably beats a dim one of similar hue-purity even
            // when the dim one covers more pixels. Verified against a
            // magenta-swirl-on-dark-teal cover (Linkin Park, "Over Each
            // Other") that was picking the teal background before this.
            let weight = s * s * v * v
            bucketWeight[bucket] += weight
            bucketR[bucket] += r * weight
            bucketG[bucket] += g * weight
            bucketB[bucket] += b * weight
            bucketPixelCount[bucket] += 1
        }

        guard opaquePixelCount > 0 else { return nil }
        let buckets = bucketWeight.indices
            .filter { bucketWeight[$0] > 0 }
            .sorted { bucketWeight[$0] > bucketWeight[$1] }
            .map { i in
                HueBucket(
                    rgb: (bucketR[i] / bucketWeight[i], bucketG[i] / bucketWeight[i], bucketB[i] / bucketWeight[i]),
                    share: Double(bucketPixelCount[i]) / Double(opaquePixelCount)
                )
            }
        return HueAnalysis(
            buckets: buckets,
            neutralShare: Double(neutralPixelCount) / Double(opaquePixelCount),
            neutralLuma: neutralPixelCount > 0 ? neutralLumaSum / CGFloat(neutralPixelCount) : 1
        )
    }

    /// A bucket below `minimumDominantShare` but at or above this still tints
    /// the accent: a black-and-white cover with a faint colour cast gets a
    /// desaturated version of that cast (the way the iPhone tints slightly
    /// coloured monochrome sleeves) instead of snapping to plain white. Only
    /// genuinely hue-free covers stay white.
    private static let minimumMutedShare: Double = 0.03

    /// A second accent must cover at least this much of the image and sit at
    /// least `minimumSecondaryHueDistance` away from the winner's hue —
    /// otherwise it's the same colour family and no real second accent exists.
    private static let minimumSecondaryShare: Double = 0.05
    /// 60° on the hue circle (distances measured as `min(d, 1-d)`, 0…0.5).
    private static let minimumSecondaryHueDistance: CGFloat = 1.0 / 6.0
    /// The third accent can be smaller and closer (45°) — by the time a cover
    /// has three real colour families, the third is usually an accent stripe,
    /// not a region.
    private static let minimumTertiaryShare: Double = 0.04
    private static let minimumTertiaryHueDistance: CGFloat = 0.125

    /// Neutral competes with the hue winner: a mostly-white/grey sleeve with
    /// an incidental face wins for the *skin tone* under pure hue voting,
    /// because grey pixels can't vote at all — and amplified skin orange is
    /// exactly the accent nobody wants. The contest weighs the winner's
    /// share by its *squared* saturation — squared because that separates
    /// pale from vivid decisively (0.35² = 0.12 vs 0.9² = 0.81): a vivid red
    /// logo on white keeps winning, a pale face doesn't — against the neutral
    /// area scaled by this bias.
    private static let neutralBias = 0.14
    /// Below this much neutral area the contest is moot — the cover is a
    /// colour cover.
    private static let minimumNeutralContestShare = 0.35

    /// The accents that dominate the artwork. `primary` falls back to a muted
    /// tint (near-monochrome cover) or white (no hue at all); nil only when
    /// the image couldn't be read/decoded. Internal rather than private so the
    /// unit tests can feed synthetic covers through the real pipeline.
    static func accents(from data: Data) -> ArtworkAccents? {
        guard let analysis = hueBuckets(from: data) else { return nil }
        guard let winner = analysis.buckets.first else {
            return ArtworkAccents(primary: .white, secondary: nil)
        }
        guard winner.share >= minimumDominantShare else {
            let primary = winner.share >= minimumMutedShare ? mutedTint(winner.rgb) : .white
            return ArtworkAccents(primary: primary, secondary: nil)
        }

        // The neutral contest (see `neutralBias`): on a mostly-white/grey
        // sleeve whose strongest hue is weak — a face, a warm cast — the
        // honest accent is silver-white, not saturated skin.
        if analysis.neutralShare >= minimumNeutralContestShare,
           analysis.neutralShare * neutralBias > winner.share * pow(Double(saturation(of: winner.rgb)), 2) {
            let luma = max(0.88, min(0.98, analysis.neutralLuma + 0.35))
            return ArtworkAccents(primary: Color(hue: 0, saturation: 0, brightness: luma), secondary: nil)
        }

        let winnerHue = hue(of: winner.rgb)
        func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let d = abs(a - b)
            return min(d, 1 - d)
        }
        let secondary = analysis.buckets.dropFirst().first { bucket in
            bucket.share >= minimumSecondaryShare
                && hueDistance(hue(of: bucket.rgb), winnerHue) >= minimumSecondaryHueDistance
        }
        let secondaryHue = secondary.map { hue(of: $0.rgb) }
        let tertiary = secondary == nil ? nil : analysis.buckets.dropFirst().first { bucket in
            guard bucket.share >= minimumTertiaryShare else { return false }
            let h = hue(of: bucket.rgb)
            return hueDistance(h, winnerHue) >= minimumTertiaryHueDistance
                && hueDistance(h, secondaryHue ?? 0) >= minimumTertiaryHueDistance
        }
        return ArtworkAccents(
            primary: vibrant(winner.rgb),
            secondary: secondary.map { vibrant($0.rgb) },
            tertiary: tertiary.map { vibrant($0.rgb) }
        )
    }

    /// The accent for an essentially monochrome cover with a faint colour
    /// cast: keep the cast's hue but stay deliberately washed out — boosting
    /// it to full vibrancy would invent a colour the sleeve doesn't have.
    private static func mutedTint(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        let ns = NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).usingColorSpace(.deviceRGB)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(0.35, s * 0.8), brightness: max(0.85, b))
    }

    // MARK: Bar palette (`.coverImage` spectrum style)

    /// Resolution the cover is sampled at. Each bar's slice has to hold enough
    /// pixels for the per-slice vote to mean something — at eight bars and a
    /// 12 % border inset this still leaves roughly 4 × 36 pixels per slice.
    private static let barSampleSide: CGFloat = 48

    /// Fraction of the cover ignored on every edge before it is split into
    /// columns. The outermost columns otherwise sit right on the sleeve's
    /// border — a frame, a vignette, the darkened edge of a photo — so the
    /// first and last bar would take their colour from the one part of the
    /// artwork that says nothing about it, and visibly break rank.
    private static let barSampleInset: Double = 0.12

    /// A hue must cover at least this share of the cover to earn a slot in the
    /// palette — lower than `minimumDominantShare`, since a secondary colour
    /// legitimately covers less ground than the dominant one.
    private static let minimumPaletteShare: Double = 0.035

    /// Minimum hue distance (0…0.5, i.e. up to 180°) between two palette
    /// entries. Measured on hue rather than RGB because that is what decides
    /// whether two entries read as *different colours*: a light and a dark blue
    /// sit far apart in RGB but should still collapse into one bar colour,
    /// while blue and green sit closer in RGB yet clearly deserve two slots.
    private static let minimumPaletteHueSeparation: CGFloat = 0.05

    /// Black/white/grey regions get their own palette slot once they cover this
    /// much of the cover, instead of being snapped onto the nearest hue — white
    /// lettering across a red sleeve should stay white, not turn pink.
    private static let minimumNeutralShare: Double = 0.25

    /// Saturation the neutral slot is drawn with when the cover has a hue to
    /// borrow. Not zero: a pure-white bar beside coloured ones reads as a
    /// different *thing*, and since the neutral regions are usually the cover's
    /// background, that lands on the outermost bars and makes the wave look
    /// broken at both ends. A washed-out version of the cover's own hue keeps
    /// every bar in one family while still reading as "no colour here".
    private static let neutralTintSaturation: CGFloat = 0.22

    /// The region of the sampled grid the bars are cut from, with the border
    /// inset already taken off (see `barSampleInset`).
    private struct SampleGeometry {
        let x0: Int, x1: Int, y0: Int, y1: Int
        var usableX: Int { x1 - x0 }
        var usableY: Int { y1 - y0 }

        init(width: Int, height: Int) {
            let insetX = Int(Double(width) * barSampleInset)
            let insetY = Int(Double(height) * barSampleInset)
            x0 = insetX
            x1 = width - insetX
            y0 = insetY
            y1 = height - insetY
        }
    }

    /// How dark the darkest brightness step draws, as a fraction of the palette
    /// colour's own brightness. Not lower: these bars sit on a black notch, and
    /// a genuinely dark one just looks like it is missing. Against
    /// `barBrightness` this puts the row's spread at 0.456…0.67, which is where
    /// the iPhone reference sits.
    private static let barDarkestLevel: CGFloat = 0.68

    /// How many colours the whole cover is reduced to. Four is enough for a
    /// sleeve with a real second and third colour and few enough that
    /// neighbouring bars still bundle into recognisable regions.
    private static let paletteSize = 4

    /// Brightness steps a bar's slice can land on. Three reads as shading;
    /// more just adds steps nobody can tell apart at this bar width.
    private static let brightnessLevels = 3

    /// The cell's brightness, snapped to `levels` steps and returned as 0…1.
    /// A single level means "flat colour" and always returns the top step.
    private static func brightnessLevel(of rgb: (r: CGFloat, g: CGFloat, b: CGFloat), levels: Int) -> CGFloat {
        guard levels > 1 else { return 1 }
        let v = max(rgb.r, max(rgb.g, rgb.b))
        let step = min(CGFloat(levels - 1), (v * CGFloat(levels)).rounded(.down))
        return step / CGFloat(levels - 1)
    }

    /// Two-stage quantisation, which is what makes the bars read as the cover
    /// rather than as a smear of it:
    ///
    /// 1. **Globally**, the whole cover is reduced to at most
    ///    `paletteSize` colours (plus a neutral slot where the sleeve
    ///    has a large black/white/grey area). Every pixel is assigned to one.
    /// 2. **Per bar**, the cover is cut into as many vertical slices as there
    ///    are bars, and each slice elects the colour that covers the most of
    ///    it. Top and bottom half vote separately, which is where the bar's
    ///    faint gradient comes from.
    ///
    /// The election is the point. Averaging a slice first invents colours the
    /// sleeve doesn't contain — red lettering on white averages to pink — and it
    /// washes out exactly the covers with the most character.
    /// Internal rather than private so `ArtworkColorTests` can hold the bars to
    /// their measured band without going through the async URL entry point.
    static func barPalette(from data: Data) -> CoverBarPalette? {
        guard let (bitmap, width, height) = sample(data, side: barSampleSide),
              width > 2, height > 3
        else { return nil }

        let geometry = SampleGeometry(width: width, height: height)

        // A palette entry matches on the *raw* cover colour and draws as the
        // vibrancy-boosted one — matching against the boosted version would
        // measure the boost rather than the artwork.
        let analysis = hueBuckets(from: data)
        var palette: [(match: (r: CGFloat, g: CGFloat, b: CGFloat), color: Color)] = []
        for bucket in (analysis?.buckets ?? []) where bucket.share >= minimumPaletteShare {
            guard palette.count < paletteSize else { break }
            // Neighbouring hue buckets often describe the same colour region
            // (two shades of the same blue). Spending a palette slot on each
            // would split bars that should read as one colour, so a new entry
            // has to be visibly different from the ones already taken.
            let hue = hue(of: bucket.rgb)
            let tooClose = palette.contains { entry in
                let d = abs(hue - self.hue(of: entry.match))
                return min(d, 1 - d) < minimumPaletteHueSeparation
            }
            if tooClose { continue }
            palette.append((bucket.rgb, barVibrant(bucket.rgb)))
        }
        if let analysis, analysis.neutralShare >= minimumNeutralShare {
            let luma = analysis.neutralLuma
            // Drawn at the same light level as every other entry rather than at
            // its measured luma: a neutral slot that keeps its own brightness
            // is the one bar that breaks the row's ramp, whether it lands too
            // dark (reads as missing) or too bright (reads as a highlight).
            // Tinted towards the cover's dominant hue where there is one.
            let color = palette.first.map {
                Color(hue: hue(of: $0.match), saturation: neutralTintSaturation, brightness: barBrightness)
            } ?? Color(white: barBrightness)
            palette.append(((luma, luma, luma), color))
        }

        // Stage one, global: every pixel of the cover is assigned to the palette
        // entry it is closest to. From here on the cover *is* those few colours.
        guard !palette.isEmpty else { return grayscaleBarPalette(bitmap: bitmap, width: width, geometry: geometry) }
        var indexOf = [Int](repeating: 0, count: width * height)
        var brightnessOf = [CGFloat](repeating: 0, count: width * height)
        for y in geometry.y0..<geometry.y1 {
            for x in geometry.x0..<geometry.x1 {
                let i = (y * width + x) * 4
                let rgb = (
                    r: CGFloat(bitmap[i]) / 255,
                    g: CGFloat(bitmap[i + 1]) / 255,
                    b: CGFloat(bitmap[i + 2]) / 255
                )
                var best = 0
                var bestDistance = CGFloat.greatestFiniteMagnitude
                for (index, entry) in palette.enumerated() {
                    let d = (entry.match.r - rgb.r) * (entry.match.r - rgb.r)
                        + (entry.match.g - rgb.g) * (entry.match.g - rgb.g)
                        + (entry.match.b - rgb.b) * (entry.match.b - rgb.b)
                    if d < bestDistance { bestDistance = d; best = index }
                }
                indexOf[y * width + x] = best
                brightnessOf[y * width + x] = max(rgb.r, max(rgb.g, rgb.b))
            }
        }

        // Stage two, per bar: each bar owns a vertical slice of the cover and
        // takes the colour that covers the most ground *within that slice* —
        // a vote, not an average. Averaging was the flaw in the earlier
        // version: a slice of red lettering on white averages to pink, which
        // is a colour that appears nowhere on the sleeve. The winner here is
        // always a colour the cover actually has, in the place the bar sits.
        func barColor(x0: Int, x1: Int, y0: Int, y1: Int) -> Color {
            var votes = [Int](repeating: 0, count: palette.count)
            var brightnessSum = [CGFloat](repeating: 0, count: palette.count)
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let index = indexOf[y * width + x]
                    votes[index] += 1
                    brightnessSum[index] += brightnessOf[y * width + x]
                }
            }
            guard let winner = votes.indices.max(by: { votes[$0] < votes[$1] }), votes[winner] > 0 else {
                return palette[0].color
            }
            // Brightness comes from the winning colour's own pixels in this
            // slice, so a bar over a shaded part of one flat colour still reads
            // darker than a bar over its lit part.
            let mean = brightnessSum[winner] / CGFloat(votes[winner])
            let level = brightnessLevel(of: (mean, mean, mean), levels: brightnessLevels)
            return shadedStep(palette[winner].color, level: level)
        }

        // One election over the bar's *whole* column, not one per half.
        //
        // Splitting it was an attractive idea — the bar mirrors its slice of
        // sleeve top to bottom — and it is wrong twice over. It hands the bar's
        // body colour to whatever occupies the top of the artwork, so a sleeve
        // with a sky, a letterbox or a bright title bar draws every bar in that
        // colour: the One Piece sleeve here is red, orange and green, and it
        // came out cyan. And it does not match the reference anyway. A bar on
        // the iPhone holds one hue from tip to foot — measured across three
        // sleeves, the hue moves under 10° over a bar's whole height while its
        // saturation and brightness drain — so the vertical run is a *drain*,
        // which `Bar` derives, not a second colour.
        //
        // Rows are derived lazily per requested count — see `CoverBarPalette`;
        // the closure captures the finished stage-one assignment, so a row
        // costs one vote pass, not a re-analysis.
        return CoverBarPalette { count in
            let elected = (0..<count).map { index -> Color in
                let x0 = geometry.x0 + index * geometry.usableX / count
                let x1 = max(x0 + 1, geometry.x0 + (index + 1) * geometry.usableX / count)
                return barColor(x0: x0, x1: min(x1, geometry.x1), y0: geometry.y0, y1: geometry.y1)
            }
            return oneFamily(elected).map { CoverBarPalette.Bar(color: $0) }
        }
    }

    /// How far a bar's hue may sit from the run's own, as a fraction of the hue
    /// circle. 20° is enough for a second colour family to read as a lean and
    /// not enough for it to read as a different colour.
    private static let maximumBarHueDeviation: CGFloat = 20.0 / 360

    /// Pulls a row's hues into a single colour family.
    ///
    /// The per-slice election is honest about the sleeve and wrong about the
    /// wave. A cover whose colours sit on opposite sides of the artwork elects
    /// one hue for every bar left of centre and another for every bar right of
    /// it, and the run draws as two blocks of colour meeting at a seam down the
    /// middle. Apple's wave never does that: a run is one material, and the
    /// sleeve shows up as its colour, not as a diagram of where that colour sits.
    ///
    /// So the hue the most bars elected sets the family, and every other bar may
    /// lean toward what it elected by `maximumBarHueDeviation`, no more.
    /// Saturation and brightness are left exactly as elected — that per-slice
    /// variation is what still makes the run read as *this* cover.
    private static func oneFamily(_ row: [Color]) -> [Color] {
        guard row.count > 1 else { return row }
        let components = row.map { HSB($0) }
        // The winner, not the mean: the average of green and purple is a hue
        // the sleeve does not contain anywhere.
        var tally: [Int: Int] = [:]
        for c in components { tally[Int((c.h * 360).rounded()), default: 0] += 1 }
        guard let winner = tally.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key else { return row }
        let family = CGFloat(winner) / 360
        return components.map { c in
            var delta = c.h - family
            if delta > 0.5 { delta -= 1 }
            if delta < -0.5 { delta += 1 }
            let lean = min(maximumBarHueDeviation, max(-maximumBarHueDeviation, delta))
            var hue = (family + lean).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            return Color(hue: hue, saturation: c.s, brightness: c.b)
        }
    }

    /// The palette colour at one of `brightnessLevels` steps — same hue and
    /// saturation, only the light changes, so bars sharing a colour still read
    /// as one family.
    private static func shadedStep(_ color: Color, level: CGFloat) -> Color {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: s, brightness: b * (barDarkestLevel + (1 - barDarkestLevel) * level))
    }

    /// Fallback for a cover with no dominant hue and no large neutral area:
    /// the same per-slice vote, but over brightness steps alone, so the bars
    /// go grey rather than borrowing a hue that isn't there.
    private static func grayscaleBarPalette(
        bitmap: [UInt8], width: Int, geometry: SampleGeometry
    ) -> CoverBarPalette {
        func barColor(x0: Int, x1: Int, y0: Int, y1: Int) -> Color {
            var sum: CGFloat = 0, n: CGFloat = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * width + x) * 4
                    sum += 0.299 * CGFloat(bitmap[i]) / 255
                        + 0.587 * CGFloat(bitmap[i + 1]) / 255
                        + 0.114 * CGFloat(bitmap[i + 2]) / 255
                    n += 1
                }
            }
            let mean = n > 0 ? sum / n : 1
            let level = brightnessLevel(of: (mean, mean, mean), levels: brightnessLevels)
            // The same band the hued bars end up in, so a black-and-white
            // sleeve sits at the wave's usual weight instead of glaring.
            return Color(white: 0.46 + (barBrightness - 0.46) * level)
        }

        return CoverBarPalette { count in
            (0..<count).map { index in
                let x0 = geometry.x0 + index * geometry.usableX / count
                let x1 = max(x0 + 1, geometry.x0 + (index + 1) * geometry.usableX / count)
                let color = barColor(x0: x0, x1: min(x1, geometry.x1), y0: geometry.y0, y1: geometry.y1)
                return CoverBarPalette.Bar(color: color)
            }
        }
    }

    private static func hue(of rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h
    }

    private static func saturation(of rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return s
    }

    /// `vibrant`'s opposite, for the spectrum bars specifically: the sleeve's
    /// colour toned *down* rather than pushed up.
    ///
    /// Measured off three iPhone now-playing waveforms — Ado *New Genesis* (a
    /// vivid pink sleeve), AAA *Wake up!* (red/orange/green) and PELICAN
    /// FANCLUB *三原色* (near-white pastel). However loud the artwork is,
    /// Apple's bars land at S 0.08–0.38, and every one of the three rows peaks
    /// at B 0.65–0.67: the pastel cover and the dark one draw at the *same*
    /// light level. Boosting was where our neon wave came from — the earlier
    /// `max(0.40, s * 1.35)` put the same covers at S 0.63–0.81.
    private static let barSaturation: ClosedRange<CGFloat> = 0.10...0.38

    /// How far the sleeve's own saturation carries into the bar. Fitted to the
    /// same three references: a raw 0.20 lands at 0.11, 0.48 at 0.26, 0.585 at
    /// 0.32. This is the dial to reach for if the wave still reads hot — not
    /// the clamp, which is what the reference actually measured.
    private static let barSaturationScale: CGFloat = 0.55

    /// One light level for every palette entry, so the row reads as a single
    /// material lit from one side. Deliberately *not* derived from the entry's
    /// own brightness: doing that is what put a magenta bar at B 0.52 next to
    /// an orange one at B 0.82, and the seam between them was visible as a
    /// break in the wave. The bar-to-bar ramp comes from `shadedStep` instead,
    /// which spreads this across 0.456…0.67 — the measured band.
    private static let barBrightness: CGFloat = 0.67

    private static func barVibrant(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        let ns = NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).usingColorSpace(.deviceRGB)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let saturation = min(barSaturation.upperBound, max(barSaturation.lowerBound, s * barSaturationScale))
        return Color(hue: h, saturation: saturation, brightness: barBrightness)
    }

    /// Boost the bucket's average into something that reads as the cover's
    /// accent — tone-mapped, not floored. The old hard floors (saturation
    /// ≥ 0.65, brightness ≥ 0.8) turned *every* cover neon and erased exactly
    /// the quality that distinguishes sleeves from one another; the iPhone's
    /// tints keep a muted cover recognizably muted. A gentle multiplier with a
    /// wide clamp lifts dull colours into legibility while leaving vivid ones
    /// nearly untouched.
    private static func vibrant(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        let ns = NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).usingColorSpace(.deviceRGB)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let saturation = min(0.92, max(0.30, s * 1.25))
        let brightness = min(0.96, max(0.68, b * 1.18))
        return Color(hue: h, saturation: saturation, brightness: brightness)
    }
}
