import CoreGraphics
import Foundation

struct Burst {
    let index: Int
    let intensity: CGFloat
}

/// All time-dependent terms are expressed in loop phase (0…1) so every periodic
/// effect completes an integer number of cycles and the clip loops seamlessly.
struct Timeline {
    let fps: Int
    let seconds: Int
    let totalFrames: Int

    static let dotCount = 5
    private static let referenceSeconds = 12.0
    private static let burstWindows: [ClosedRange<Double>] = [
        0.40...1.60, 2.40...2.90, 3.60...5.20, 6.00...6.50, 7.20...8.80, 9.60...10.10, 10.80...11.60,
    ]
    private static let easeSeconds = 0.12
    private static let envelopeKnotSeconds = 0.2
    private static let lightFrameChance: CGFloat = 0.2
    private static let dotStepSeconds = 0.3

    init(fps: Int, seconds: Int) {
        self.fps = fps
        self.seconds = seconds
        self.totalFrames = fps * seconds
    }

    func phase(_ frame: Int) -> Double { Double(frame) / Double(totalFrames) }

    func burst(at frame: Int) -> Burst? {
        let time = Double(frame) / Double(fps)
        let scale = Double(seconds) / Self.referenceSeconds
        for (index, window) in Self.burstWindows.enumerated() {
            let start = window.lowerBound * scale, end = window.upperBound * scale
            guard time > start, time < end else { continue }
            let edge = min(Self.easeSeconds * scale, (end - start) * 0.3)
            let ease = Self.smoothstep(min(1, min(time - start, end - time) / edge))
            let level = Self.envelope(burst: index, progress: (time - start) / (end - start), seconds: end - start)
            return Burst(index: index, intensity: CGFloat(ease * level) * Self.frameJitter(frame))
        }
        return nil
    }

    /// Seeded random knots, smoothly interpolated, with one guaranteed full-strength peak,
    /// so each burst swells and fades in its own way.
    private static func envelope(burst: Int, progress: Double, seconds: Double) -> Double {
        var rng = SeededRandom(seed: UInt64(burst), salt: 0xE7E1)
        let count = max(3, Int(seconds / envelopeKnotSeconds) + 1)
        let peak = rng.int(1...(count - 2))
        let knots = (0..<count).map { $0 == peak ? 1 : Double(rng.range(0.3...0.95)) }
        let position = progress * Double(count - 1)
        let lower = min(Int(position), count - 2)
        let t = smoothstep(position - Double(lower))
        return knots[lower] + (knots[lower + 1] - knots[lower]) * t
    }

    /// Most frames near the envelope, about one in five much lighter: the flicker of a bad signal.
    private static func frameJitter(_ frame: Int) -> CGFloat {
        var rng = SeededRandom(seed: UInt64(frame), salt: 0xF11C)
        return rng.unit() < lightFrameChance ? rng.range(0.15...0.45) : rng.range(0.75...1)
    }

    /// Index of the bright loading square; step count is rounded to a multiple of the
    /// square count so the sequence wraps cleanly at the loop point.
    func dotStep(_ frame: Int) -> Int {
        let rawSteps = Double(seconds) / Self.dotStepSeconds
        let steps = max(Self.dotCount, Int((rawSteps / Double(Self.dotCount)).rounded()) * Self.dotCount)
        return Int(phase(frame) * Double(steps)) % Self.dotCount
    }

    static func wave(_ phase: Double, cycles: Int, offset: Double = 0) -> CGFloat {
        CGFloat(sin(2 * Double.pi * (Double(cycles) * phase + offset)))
    }

    static func fract(_ value: CGFloat) -> CGFloat { value - floor(value) }

    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
