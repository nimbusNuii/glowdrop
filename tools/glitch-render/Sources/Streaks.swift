import CoreGraphics
import CoreImage

struct StreakSpec {
    let y: CGFloat
    let height: CGFloat
    let length: CGFloat
    let opacity: CGFloat
    let start: CGFloat
    let wraps: Int
    let flickerCycles: Int
    let flickerOffset: Double
    let textureOffset: CGFloat
}

/// Horizontal noise bars, textured from one shared 1-px strip of random dashes.
struct StreakPainter {
    private static let stripWidth = 2048

    let canvas: CGRect
    let ambient: [StreakSpec]
    private let strip: CIImage
    private let texelScale: CGFloat

    init(canvas: CGRect) throws {
        self.canvas = canvas
        self.strip = try Self.makeStrip()
        self.texelScale = max(1, 2 * canvas.height / 1200)
        self.ambient = Self.ambientSpecs(canvas: canvas)
    }

    func ambientLayer(phase: Double, color: RGB) -> CIImage {
        ambient.reduce(CIImage.empty()) { result, spec in
            let travel = canvas.width + spec.length
            let x = Timeline.fract(spec.start + CGFloat(spec.wraps) * CGFloat(phase)) * travel - spec.length
            let flicker = 0.55 + 0.45 * Timeline.wave(phase, cycles: spec.flickerCycles, offset: spec.flickerOffset)
            let rect = CGRect(x: x, y: spec.y, width: spec.length, height: spec.height)
            return bar(rect, textureOffset: spec.textureOffset, color: color,
                       opacity: spec.opacity * flicker).composited(over: result)
        }
    }

    /// Bright tint-to-white tears spawned on every burst frame; the quartic term crowds the peaks.
    func burstLayer(intensity: CGFloat, color: RGB, rng: inout SeededRandom) -> CIImage {
        let count = Int((rng.range(4...12) * intensity + 12 * pow(intensity, 4)).rounded())
        return (0..<count).reduce(CIImage.empty()) { result, _ in
            let rect = CGRect(x: rng.range(-0.1...0.9) * canvas.width, y: rng.range(0.18...0.82) * canvas.height,
                              width: rng.range(0.05...0.40) * canvas.width,
                              height: rng.range(0.002...0.006) * canvas.height)
            let tear = color.mixed(toward: .white, rng.unit())
            return bar(rect, textureOffset: rng.unit(), color: tear,
                       opacity: rng.range(0.55...1) * intensity, solidCore: 0.35).composited(over: result)
        }
    }

    /// `solidCore` fills the texture's gaps at that fraction so tears read as bars, not dashes.
    private func bar(_ rawRect: CGRect, textureOffset: CGFloat, color: RGB, opacity: CGFloat,
                     solidCore: CGFloat = 0) -> CIImage {
        let rect = CGRect(x: rawRect.minX.rounded(), y: rawRect.minY.rounded(),
                          width: max(1, rawRect.width.rounded()), height: max(1, rawRect.height.rounded()))
        let segment = min(CGFloat(Self.stripWidth - 1), max(1, rect.width / texelScale))
        let offset = (textureOffset * (CGFloat(Self.stripWidth) - segment)).rounded()
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / segment, y: 1)
            .translatedBy(x: -offset, y: 0)
        // Clamp so the 1-px strip extends vertically and its ends do not fade under scaling.
        let textured = strip.cropped(to: CGRect(x: offset, y: 0, width: segment, height: 1))
            .clampedToExtent()
            .transformed(by: transform)
            .cropped(to: rect)
            .tinted(color, opacity: opacity)
        guard solidCore > 0 else { return textured }
        let core = CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b))
            .cropped(to: rect)
            .opacity(opacity * solidCore)
        return textured.composited(over: core)
    }

    private static func ambientSpecs(canvas: CGRect) -> [StreakSpec] {
        var rng = SeededRandom(seed: 0x5EED, salt: 18)
        return (0..<18).map { _ in
            StreakSpec(y: rng.range(0.08...0.92) * canvas.height,
                       height: rng.range(0.0015...0.004) * canvas.height,
                       length: rng.range(0.04...0.32) * canvas.width,
                       opacity: rng.range(0.07...0.22),
                       start: rng.unit(),
                       wraps: rng.int(1...3) * Int(rng.sign()),
                       flickerCycles: rng.int(6...48),
                       flickerOffset: Double(rng.unit()),
                       textureOffset: rng.unit())
        }
    }

    /// Random-length dashes of random brightness: white, premultiplied.
    private static func makeStrip() throws -> CIImage {
        var rng = SeededRandom(seed: 0x57819, salt: 1)
        let levels = (0..<(stripWidth / 2)).flatMap { _ -> [CGFloat] in
            let run = rng.int(2...40)
            let level = rng.unit() < 0.6 ? rng.range(0.35...1) : 0
            return (0..<run).map { _ in level * rng.range(0.8...1) }
        }.prefix(stripWidth)
        let bytes = levels.flatMap { level -> [UInt8] in
            let value = UInt8((level * 255).rounded())
            return [value, value, value, value]
        }
        return try Raster.image(width: stripWidth, height: 1, rgba: Array(bytes))
    }
}
