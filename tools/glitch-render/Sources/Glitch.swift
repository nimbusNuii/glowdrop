import CoreGraphics
import CoreImage

struct GlitchBand {
    let lower: CGFloat
    let upper: CGFloat
    let shift: CGFloat
    let gain: CGFloat
}

/// Horizontal tearing of the logo layer, modelled on a lost-sync CRT look.
enum Glitch {
    private static let dropoutChance: CGFloat = 0.14
    private static let dropoutGain: CGFloat = 0.2
    private static let jitterMaxShift: CGFloat = 0.004
    private static let smearRadius: CGFloat = 0.07
    private static let smearOpacity: CGFloat = 0.9

    static func bands(for bounds: CGRect, canvasWidth: CGFloat, intensity: CGFloat,
                      rng: inout SeededRandom) -> [GlitchBand] {
        let count = rng.int(8...12) + Int(24 * intensity)
        let cuts = (1..<count).map { _ in rng.range(bounds.minY...bounds.maxY).rounded() }.sorted()
        let edges = [bounds.minY] + cuts + [bounds.maxY]
        return zip(edges, edges.dropFirst()).map { lower, upper in
            // A few bands tear much further than the rest, like a lost sync pulse.
            let tear: CGFloat = rng.unit() < 0.18 ? rng.range(2.0...3.5) : 1
            // Squared so most rows slip a little and only a few slip far.
            let shift = rng.sign() * pow(rng.unit(), 2) * 0.045 * canvasWidth * tear * intensity
            let gain = rng.unit() < dropoutChance * intensity
                ? dropoutGain
                : 1 + (rng.range(0.7...1.3) - 1) * intensity
            return GlitchBand(lower: lower, upper: upper, shift: shift.rounded(), gain: gain)
        }
    }

    /// Between bursts: 1–3 thin rows nudged by at most `jitterMaxShift` of the width, the rest untouched.
    static func jitterBands(for bounds: CGRect, canvasWidth: CGFloat, rng: inout SeededRandom) -> [GlitchBand] {
        let nudged = (0..<rng.int(1...3)).map { _ -> GlitchBand in
            let height = (rng.range(0.02...0.08) * bounds.height).rounded()
            let lower = rng.range(bounds.minY...(bounds.maxY - height)).rounded()
            let shift = (rng.sign() * rng.range(0.25...1) * jitterMaxShift * canvasWidth).rounded()
            return GlitchBand(lower: lower, upper: lower + height, shift: shift, gain: 1)
        }
        let edges = Set([bounds.minY, bounds.maxY] + nudged.flatMap { [$0.lower, $0.upper] }).sorted()
        return zip(edges, edges.dropFirst()).map { lower, upper in
            let shift = nudged.first { $0.lower <= lower && upper <= $0.upper }?.shift ?? 0
            return GlitchBand(lower: lower, upper: upper, shift: shift, gain: 1)
        }
    }

    static func slice(_ image: CIImage, bands: [GlitchBand], applyGain: Bool) -> CIImage {
        let extent = image.extent
        return bands.reduce(CIImage.empty()) { result, band in
            let strip = image
                .cropped(to: CGRect(x: extent.minX, y: band.lower, width: extent.width, height: band.upper - band.lower))
                .translated(band.shift)
            return (applyGain ? strip.gain(band.gain) : strip).composited(over: result)
        }
    }

    /// Red copy shifted left, blue copy shifted right, each at 50 %.
    static func rgbSplit(_ image: CIImage, offset: CGFloat) -> (red: CIImage, blue: CIImage) {
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        let halfAlpha = CIVector(x: 0, y: 0, z: 0, w: 0.5)
        let red = image.colorMatrix(r: CIVector(x: 1, y: 0, z: 0, w: 0), g: zero, b: zero, a: halfAlpha)
        let blue = image.colorMatrix(r: zero, g: zero, b: CIVector(x: 0, y: 0, z: 1, w: 0), a: halfAlpha)
        return (red.translated(-offset.rounded()), blue.translated(offset.rounded()))
    }

    /// Ghost copies offset ±1–4 % of the width plus a horizontal motion blur broken into streaks
    /// by `texture`: the smeared, dragged look of the logo. Screen it over the torn logo.
    static func smear(_ image: CIImage, canvasWidth: CGFloat, intensity: CGFloat, texture: CIImage,
                      rng: inout SeededRandom) -> CIImage {
        let copies = (0..<rng.int(2...4)).reduce(CIImage.empty()) { result, _ in
            let dx = (rng.sign() * rng.range(0.01...0.04) * canvasWidth).rounded()
            return image.translated(dx).opacity(rng.range(0.15...0.35) * intensity).screened(over: result)
        }
        let radius = canvasWidth * smearRadius * rng.range(0.5...1) * intensity
        let streaks = texture.multiplied(over: image.horizontallySmeared(radius: radius))
        return streaks.opacity(smearOpacity * intensity).screened(over: copies)
    }
}
