import CoreGraphics
import CoreImage
import Foundation

/// Composes one frame from the cached layers. Frames are pure functions of the index.
struct SceneRenderer {
    private static let glowOpacity: CGFloat = 0.55
    private static let glowBreath: CGFloat = 0.08
    private static let rgbSplitFraction: CGFloat = 0.008
    private static let idleFlicker: CGFloat = 0.05
    private static let jitterChance: CGFloat = 0.35
    /// Idle jitter is held for a few frames so it reads as a slipping signal, not shimmer.
    private static let jitterRate = 15

    let canvas: CGRect
    private let timeline: Timeline
    private let palette: Palette
    private let logo: LogoAssets
    private let hud: HUDAssets
    private let streaks: StreakPainter
    private let effects: Effects
    private let interference: Interference

    init(width: Int, height: Int, timeline: Timeline, context: CIContext, palette: Palette,
         logoMask: LogoMask, hudText: HUDText) throws {
        let size = CGSize(width: width, height: height)
        canvas = CGRect(origin: .zero, size: size)
        self.timeline = timeline
        self.palette = palette
        logo = try LogoRenderer.make(canvas: size, context: context, palette: palette, mask: logoMask)
        hud = try HUDRenderer.make(canvas: size, context: context, text: hudText)
        streaks = try StreakPainter(canvas: canvas)
        effects = try Effects(canvas: canvas, background: palette.background)
        interference = try Interference(canvas: canvas)
    }

    func image(forFrame frame: Int) -> CIImage {
        let phase = timeline.phase(frame)
        let intensity = timeline.burst(at: frame)?.intensity ?? 0
        var rng = SeededRandom(seed: UInt64(frame), salt: 0xF2A3E)
        let tint = palette.streakColor(phase: phase)
        let noiseTint = palette.noiseColor(phase: phase)

        let ambient = streaks.ambientLayer(phase: phase, color: tint).dodged(over: effects.background)
        let withLogo = intensity > 0
            ? composeTornLogo(onto: ambient, phase: phase, intensity: intensity, rng: &rng)
            : composeIdleLogo(onto: ambient, phase: phase, frame: frame, rng: &rng)
        let lined = interference.lineNoise(intensity: intensity, tint: noiseTint, rng: &rng).dodged(over: withLogo)
        let disturbed = intensity > 0
            ? addBurstNoise(onto: lined, intensity: intensity, tints: (tint, noiseTint), rng: &rng)
            : lined
        let withHUD = composeHUD(onto: effects.vignette.multiplied(over: disturbed), frame: frame, phase: phase)
        let refreshed = effects.refreshBand(phase: phase, tint: tint).dodged(over: withHUD)
        let scanned = effects.scanlines.multiplied(over: refreshed).gain(Self.flicker(phase))
        return interference.grain(rng: &rng).linearLit(over: scanned).cropped(to: canvas)
    }

    /// Between bursts the logo is never quite clean: a slight flicker and, now and then, a few nudged rows.
    private func composeIdleLogo(onto base: CIImage, phase: Double, frame: Int, rng: inout SeededRandom) -> CIImage {
        let paint = logo.frame(phase: phase)
        let gain = 1 - Self.idleFlicker * rng.unit()
        var slot = SeededRandom(seed: UInt64(frame / max(1, timeline.fps / Self.jitterRate)), salt: 0x7177)
        let crisp = slot.unit() < Self.jitterChance
            ? Glitch.slice(paint.crisp, bands: Glitch.jitterBands(for: logo.bounds, canvasWidth: canvas.width,
                                                                  rng: &slot), applyGain: false)
            : paint.crisp
        return paint.glow.opacity(glowStrength(phase) * gain).screened(over: crisp.gain(gain).composited(over: base))
    }

    private func composeTornLogo(onto base: CIImage, phase: Double, intensity: CGFloat,
                                 rng: inout SeededRandom) -> CIImage {
        let paint = logo.frame(phase: phase)
        let bands = Glitch.bands(for: logo.bounds, canvasWidth: canvas.width, intensity: intensity, rng: &rng)
        let crisp = Glitch.slice(paint.crisp, bands: bands, applyGain: true)
        // The torn logo differs every frame, so its glow must be re-blurred instead of cached.
        let glow = Glitch.slice(paint.glowSource, bands: bands, applyGain: false).softBlurred(sigma: logo.glowSigma)
        let smear = Glitch.smear(crisp, canvasWidth: canvas.width, intensity: intensity,
                                 texture: interference.streakTexture(rng: &rng), rng: &rng)
        let split = Glitch.rgbSplit(crisp, offset: canvas.width * Self.rgbSplitFraction * intensity * rng.range(0.4...1))
        let withSplit = split.blue.screened(over: split.red.screened(over: crisp.composited(over: base)))
        return glow.opacity(glowStrength(phase)).screened(over: smear.screened(over: withSplit))
    }

    /// Static bands, bright tears and a whole-frame colour fringe — all under the steady HUD.
    private func addBurstNoise(onto image: CIImage, intensity: CGFloat, tints: (streak: RGB, noise: RGB),
                               rng: inout SeededRandom) -> CIImage {
        let banded = interference.staticBands(intensity: intensity, tint: tints.noise, rng: &rng).dodged(over: image)
        let torn = streaks.burstLayer(intensity: intensity, color: tints.streak, rng: &rng).dodged(over: banded)
        return effects.chromaticAberration(torn, strength: intensity)
    }

    private func composeHUD(onto base: CIImage, frame: Int, phase: Double) -> CIImage {
        let color = palette.hudColor(phase: phase)
        let dots = hud.dotStates[timeline.dotStep(frame)].tinted(color, opacity: 1)
        return dots.composited(over: hud.staticLayer.tinted(color, opacity: 1).composited(over: base))
    }

    private func glowStrength(_ phase: Double) -> CGFloat {
        Self.glowOpacity * (1 + Self.glowBreath * Timeline.wave(phase, cycles: 2))
    }

    /// ±1.5 % brightness from two sines with integer cycle counts per loop.
    private static func flicker(_ phase: Double) -> CGFloat {
        1 + 0.0075 * Timeline.wave(phase, cycles: 25) + 0.0075 * Timeline.wave(phase, cycles: 150, offset: 0.37)
    }
}
