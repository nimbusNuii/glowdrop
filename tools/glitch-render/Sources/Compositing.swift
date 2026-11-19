import CoreImage
import CoreImage.CIFilterBuiltins

/// Thin wrappers over built-in CI filters. `applyingFilter` silently yields an empty image
/// for an unknown filter name, so every name used here is checked once at startup.
enum Compositing {
    static let requiredFilters = [
        "CIScreenBlendMode", "CILinearDodgeBlendMode", "CILinearLightBlendMode",
        "CIMultiplyCompositing", "CIMaximumCompositing", "CIColorMatrix",
        "CIAffineTile", "CIRadialGradient", "CIGaussianBlur", "CIMotionBlur", "CIGammaAdjust",
    ]

    static func validateFilters() throws {
        let missing = requiredFilters.filter { CIFilter(name: $0) == nil }
        guard missing.isEmpty else {
            throw RenderError("Core Image filters unavailable: \(missing.joined(separator: ", "))")
        }
    }
}

extension CIImage {
    func screened(over base: CIImage) -> CIImage { blended("CIScreenBlendMode", over: base) }
    func dodged(over base: CIImage) -> CIImage { blended("CILinearDodgeBlendMode", over: base) }
    func multiplied(over base: CIImage) -> CIImage { blended("CIMultiplyCompositing", over: base) }
    func maximum(over base: CIImage) -> CIImage { blended("CIMaximumCompositing", over: base) }
    /// Linear light with a 0.5-centred layer adds a signed offset — used for film grain.
    func linearLit(over base: CIImage) -> CIImage { blended("CILinearLightBlendMode", over: base) }

    func translated(_ dx: CGFloat, _ dy: CGFloat = 0) -> CIImage {
        transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    /// Scales alpha (and therefore premultiplied colour) by `amount`.
    func opacity(_ amount: CGFloat) -> CIImage {
        colorMatrix(r: CIVector(x: 1, y: 0, z: 0, w: 0), g: CIVector(x: 0, y: 1, z: 0, w: 0),
                    b: CIVector(x: 0, y: 0, z: 1, w: 0), a: CIVector(x: 0, y: 0, z: 0, w: amount))
    }

    /// Multiplies colour, keeping alpha — brightness changes.
    func gain(_ k: CGFloat) -> CIImage { tinted(RGB(r: k, g: k, b: k), opacity: 1) }

    /// Multiplies each channel by `color` and alpha by `opacity`.
    func tinted(_ color: RGB, opacity: CGFloat) -> CIImage {
        colorMatrix(r: CIVector(x: color.r, y: 0, z: 0, w: 0), g: CIVector(x: 0, y: color.g, z: 0, w: 0),
                    b: CIVector(x: 0, y: 0, z: color.b, w: 0), a: CIVector(x: 0, y: 0, z: 0, w: opacity))
    }

    func colorMatrix(r: CIVector, g: CIVector, b: CIVector, a: CIVector,
                     bias: CIVector = CIVector(x: 0, y: 0, z: 0, w: 0)) -> CIImage {
        applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": r, "inputGVector": g, "inputBVector": b, "inputAVector": a, "inputBiasVector": bias,
        ])
    }

    /// Gaussian blur computed at 1/`factor` resolution: the result is smooth, so upscaling it
    /// back is invisible and far cheaper than a large-sigma blur on a 4K layer.
    func softBlurred(sigma: CGFloat, factor: CGFloat = 4) -> CIImage {
        let shrink = CGAffineTransform(scaleX: 1 / factor, y: 1 / factor)
        return transformed(by: shrink).applyingGaussianBlur(sigma: sigma / factor).transformed(by: shrink.inverted())
    }

    /// Horizontal motion blur on an x-squeezed copy; the blur discards x detail anyway.
    func horizontallySmeared(radius: CGFloat, factor: CGFloat = 4) -> CIImage {
        let squeeze = CGAffineTransform(scaleX: 1 / factor, y: 1)
        return transformed(by: squeeze)
            .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius / factor, kCIInputAngleKey: 0])
            .transformed(by: squeeze.inverted())
    }

    /// Repeats the image infinitely in both directions.
    func tiled() throws -> CIImage {
        let filter = CIFilter.affineTile()
        filter.inputImage = self
        filter.transform = .identity
        guard let output = filter.outputImage else { throw RenderError("affine tile failed") }
        return output
    }

    private func blended(_ filter: String, over base: CIImage) -> CIImage {
        applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: base])
    }
}
