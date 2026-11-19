import CoreGraphics
import CoreImage

/// Noise-driven interference from a few cached random tiles. Per frame only the tile choice,
/// offset and stretch change, so no noise is ever generated at full resolution.
struct Interference {
    private static let tileSize = 512
    private static let tileCount = 8
    private static let grainAmplitude: CGFloat = 0.04
    /// One noise cell becomes a line segment hundreds of pixels long: thin full-width lines.
    private static let lineStretch: CGFloat = 240
    private static let linePower: CGFloat = 3
    private static let idleLineOpacity: CGFloat = 0.25
    private static let burstLineOpacity: CGFloat = 0.5
    private static let bandPower: CGFloat = 1.6
    private static let streakStretch: CGFloat = 80
    private static let profileHeight = 256
    /// Line density at the top and bottom edges relative to the middle band.
    private static let profileEdge: CGFloat = 0.3

    let canvas: CGRect
    private let noiseTiles: [CIImage]
    private let lineProfile: CIImage

    init(canvas: CGRect) throws {
        self.canvas = canvas
        let cell = max(1, Int((canvas.height / 1200).rounded()))
        noiseTiles = try (0..<Self.tileCount).map { try Self.makeNoiseTile(index: $0, cell: cell) }
        lineProfile = try Self.makeLineProfile(canvas: canvas)
    }

    /// Noise remapped to 0.5 ± amplitude/2 so linear light adds ± amplitude.
    func grain(rng: inout SeededRandom) -> CIImage {
        let a = Self.grainAmplitude, offset = 0.5 - Self.grainAmplitude / 2
        return noise(rng: &rng, stretch: 1).colorMatrix(
            r: CIVector(x: a, y: 0, z: 0, w: 0), g: CIVector(x: 0, y: a, z: 0, w: 0), b: CIVector(x: 0, y: 0, z: a, w: 0),
            a: CIVector(x: 0, y: 0, z: 0, w: 1), bias: CIVector(x: offset, y: offset, z: offset, w: 0)
        ).cropped(to: canvas)
    }

    /// Dense thin horizontal lines of random brightness over the whole frame; faint between bursts.
    func lineNoise(intensity: CGFloat, tint: RGB, rng: inout SeededRandom) -> CIImage {
        let opacity = Self.idleLineOpacity + Self.burstLineOpacity * intensity
        let lines = Self.glowing(noise(rng: &rng, stretch: Self.lineStretch), power: Self.linePower, tint: tint,
                                 opacity: opacity)
        return lineProfile.multiplied(over: lines).cropped(to: canvas)
    }

    /// Patches of horizontally smeared static, denser and brighter towards burst peaks.
    func staticBands(intensity: CGFloat, tint: RGB, rng: inout SeededRandom) -> CIImage {
        let count = Int((rng.range(2...6) * intensity + 4 * intensity * intensity).rounded())
        return (0..<count).reduce(CIImage.empty()) { result, _ in
            let rect = CGRect(x: rng.range(-0.3...0.7) * canvas.width, y: rng.range(0.12...0.88) * canvas.height,
                              width: rng.range(0.25...0.9) * canvas.width,
                              height: rng.range(0.008...0.06) * canvas.height).integral
            let stretch = rng.range(30...60)
            let opacity = rng.range(0.25...0.8) * intensity
            return Self.glowing(noise(rng: &rng, stretch: stretch), power: Self.bandPower, tint: tint, opacity: opacity)
                .cropped(to: rect)
                .composited(over: result)
        }
    }

    /// White row noise used to break a smear into separate streaks (premultiplied, alpha = brightness).
    func streakTexture(rng: inout SeededRandom) -> CIImage {
        Self.glowing(noise(rng: &rng, stretch: Self.streakStretch), power: 1, tint: .white, opacity: 1)
    }

    /// A random tile at a random offset, stretched horizontally by `stretch`.
    private func noise(rng: inout SeededRandom, stretch: CGFloat) -> CIImage {
        let tile = noiseTiles[rng.int(0...(Self.tileCount - 1))]
        let dx = CGFloat(rng.int(0...(Self.tileSize - 1)))
        let dy = CGFloat(rng.int(0...(Self.tileSize - 1)))
        return tile.translated(dx, dy).transformed(by: CGAffineTransform(scaleX: stretch, y: 1))
    }

    /// Gray noise → premultiplied tinted light: the power keeps most of it dark with a few bright dashes.
    private static func glowing(_ gray: CIImage, power: CGFloat, tint: RGB, opacity: CGFloat) -> CIImage {
        gray.applyingFilter("CIGammaAdjust", parameters: ["inputPower": power]).colorMatrix(
            r: CIVector(x: tint.r * opacity, y: 0, z: 0, w: 0), g: CIVector(x: tint.g * opacity, y: 0, z: 0, w: 0),
            b: CIVector(x: tint.b * opacity, y: 0, z: 0, w: 0), a: CIVector(x: opacity, y: 0, z: 0, w: 0))
    }

    /// Monochrome uniform noise in square cells, tiled infinitely.
    private static func makeNoiseTile(index: Int, cell: Int) throws -> CIImage {
        var rng = SeededRandom(seed: UInt64(index), salt: 0x6A41)
        let cellsPerRow = tileSize / cell
        let cells = (0..<(cellsPerRow * cellsPerRow)).map { _ in UInt8(rng.int(0...255)) }
        let bytes = (0..<(tileSize * tileSize)).flatMap { pixel -> [UInt8] in
            let column = (pixel % tileSize) / cell, row = (pixel / tileSize) / cell
            let value = cells[min(row, cellsPerRow - 1) * cellsPerRow + min(column, cellsPerRow - 1)]
            return [value, value, value, 255]
        }
        return try Raster.image(width: tileSize, height: tileSize, rgba: bytes).tiled()
    }

    /// Vertical weight (premultiplied white): full strength over the middle, `profileEdge` at the edges.
    private static func makeLineProfile(canvas: CGRect) throws -> CIImage {
        let bytes = (0..<profileHeight).flatMap { row -> [UInt8] in
            let s = sin(CGFloat.pi * (CGFloat(row) + 0.5) / CGFloat(profileHeight))
            let value = UInt8(((profileEdge + (1 - profileEdge) * s.squareRoot()) * 255).rounded())
            return [value, value, value, value]
        }
        let scale = canvas.height / CGFloat(profileHeight)
        return try Raster.image(width: 1, height: profileHeight, rgba: bytes).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1, y: scale))
    }
}
