import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Full-frame CRT treatments. Everything expensive is built once in `init`; per-frame
/// methods only reposition or recolour cached images.
struct Effects {
    private static let refreshPasses = 3
    private static let refreshProfileHeight = 256
    /// How far the refresh band's tint is pulled towards white.
    private static let refreshWhiteMix: CGFloat = 0.55

    let canvas: CGRect
    let background: CIImage
    let vignette: CIImage
    let scanlines: CIImage
    private let refreshProfile: CIImage

    init(canvas: CGRect, background color: RGB) throws {
        self.canvas = canvas
        background = CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b)).cropped(to: canvas)
        vignette = try Self.makeVignette(canvas: canvas)
        scanlines = try Self.makeScanlines(canvas: canvas)
        refreshProfile = try Self.makeRefreshProfile()
    }

    /// Soft light band rolling top → bottom, `refreshPasses` times per loop.
    func refreshBand(phase: Double, tint: RGB) -> CIImage {
        let height = (canvas.height * 0.13).rounded()
        let progress = Timeline.fract(CGFloat(phase) * CGFloat(Self.refreshPasses))
        let bottom = (canvas.height - progress * (canvas.height + height)).rounded()
        let scale = height / CGFloat(Self.refreshProfileHeight)
        return refreshProfile
            .transformed(by: CGAffineTransform(translationX: 0, y: bottom).scaledBy(x: 1, y: scale))
            .cropped(to: CGRect(x: canvas.minX, y: bottom, width: canvas.width, height: height))
            .tinted(tint.mixed(toward: .white, Self.refreshWhiteMix), opacity: 1)
    }

    /// Red sampled from the right, blue from the left, green in place.
    func chromaticAberration(_ image: CIImage, strength: CGFloat) -> CIImage {
        let shift = (canvas.width * 0.0012 * strength).rounded()
        guard shift >= 1 else { return image }
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        let keepAlpha = CIVector(x: 0, y: 0, z: 0, w: 1)
        let clamped = image.clampedToExtent()
        let red = clamped.translated(-shift)
            .colorMatrix(r: CIVector(x: 1, y: 0, z: 0, w: 0), g: zero, b: zero, a: keepAlpha)
        let green = image.colorMatrix(r: zero, g: CIVector(x: 0, y: 1, z: 0, w: 0), b: zero, a: keepAlpha)
        let blue = clamped.translated(shift)
            .colorMatrix(r: zero, g: zero, b: CIVector(x: 0, y: 0, z: 1, w: 0), a: keepAlpha)
        return red.maximum(over: green).maximum(over: blue).cropped(to: canvas)
    }

    /// Elliptical gradient: 1.0 in the middle, ~0.65 towards the corners.
    private static func makeVignette(canvas: CGRect) throws -> CIImage {
        let gradient = CIFilter.radialGradient()
        gradient.center = .zero
        gradient.radius0 = Float(canvas.height * 0.25)
        gradient.radius1 = Float(canvas.height * 0.62)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
        gradient.color1 = CIColor(red: 0.65, green: 0.65, blue: 0.65)
        guard let output = gradient.outputImage else { throw RenderError("vignette gradient failed") }
        let transform = CGAffineTransform(translationX: canvas.midX, y: canvas.midY)
            .scaledBy(x: canvas.width / canvas.height, y: 1)
        return output.transformed(by: transform).cropped(to: canvas)
    }

    /// Every 4th row darkened 22 %.
    private static func makeScanlines(canvas: CGRect) throws -> CIImage {
        let dark: UInt8 = 199
        let rows: [UInt8] = [255, 255, 255, dark]
        let tile = try Raster.image(width: 1, height: 4, rgba: rows.flatMap { [$0, $0, $0, 255] })
        return try tile.tiled().cropped(to: canvas)
    }

    private static func makeRefreshProfile() throws -> CIImage {
        let peak: CGFloat = 0.10
        let bytes = (0..<refreshProfileHeight).flatMap { row -> [UInt8] in
            let s = sin(CGFloat.pi * (CGFloat(row) + 0.5) / CGFloat(refreshProfileHeight))
            let a = UInt8((peak * s * s * 255).rounded())
            return [a, a, a, a]
        }
        return try Raster.image(width: 1, height: refreshProfileHeight, rgba: bytes).clampedToExtent()
    }
}
