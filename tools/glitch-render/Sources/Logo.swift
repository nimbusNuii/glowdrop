import CoreGraphics
import CoreImage

struct LogoFrame {
    let crisp: CIImage
    let glowSource: CIImage
    let glow: CIImage
}

struct LogoAssets {
    let crisp: CIImage
    let glowSource: CIImage
    let cachedGlow: CIImage
    let glowSigma: CGFloat
    let bounds: CGRect
    /// Rainbow palette only: `crisp` and `glowSource` are then white and get coloured per frame.
    let hueField: HueField?

    func frame(phase: Double) -> LogoFrame {
        guard let hueField else { return LogoFrame(crisp: crisp, glowSource: glowSource, glow: cachedGlow) }
        let hue = hueField.image(phase: phase).cropped(to: bounds)
        let source = hue.multiplied(over: glowSource)
        return LogoFrame(crisp: hue.multiplied(over: crisp), glowSource: source,
                         glow: source.softBlurred(sigma: glowSigma))
    }
}

enum LogoRenderer {
    private static let dimStripe: CGFloat = 0.72
    private static let maxWidthFraction: CGFloat = 0.7

    static func make(canvas: CGSize, context: CIContext, palette: Palette, mask: LogoMask) throws -> LogoAssets {
        let boxRect = logoRect(canvas: canvas, mask: mask)
        let bounds = boxRect.insetBy(dx: -boxRect.width * 0.04, dy: -boxRect.height * 0.04).integral
        let clip = try coverageClip(boxRect: boxRect, bounds: bounds, mask: mask)
        let paint = try fillPainter(palette.fill, boxRect: boxRect)
        let stripeRows = max(1, (canvas.height * 0.0025).rounded())

        let crisp = try Raster.draw(region: bounds) { ctx in
            clip(ctx)
            paint(ctx, bounds)
            darkenAlternateRows(ctx, bounds: bounds, rowHeight: stripeRows)
        }
        let glowColor = palette.isRainbow ? RGB.white : palette.glow
        let glowSource = try Raster.draw(region: bounds) { ctx in
            clip(ctx)
            ctx.setFillColor(glowColor.cgColor())
            ctx.fill(bounds)
        }
        let sigma = canvas.width * 0.012
        let cachedGlow = try Raster.bake(glowSource.applyingGaussianBlur(sigma: sigma), context: context)
        let hueField: HueField? = try palette.isRainbow ? HueField(period: hypot(bounds.width, bounds.height)) : nil
        return LogoAssets(crisp: crisp, glowSource: glowSource, cachedGlow: cachedGlow,
                          glowSigma: sigma, bounds: bounds, hueField: hueField)
    }

    private static func logoRect(canvas: CGSize, mask: LogoMask) -> CGRect {
        // Wide (text) logos shrink to fit the canvas width; --logo-height is the upper bound.
        let height = min(canvas.height * mask.heightFraction, canvas.width * maxWidthFraction / mask.aspect)
        let size = CGSize(width: height * mask.aspect, height: height)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The single source of "logo coverage": the mask scaled into the logo rect.
    private static func coverageClip(boxRect: CGRect, bounds: CGRect, mask: LogoMask) throws -> (CGContext) -> Void {
        let coverage = try mask.coverage(rect: boxRect, bounds: bounds)
        return { ctx in ctx.clip(to: bounds, mask: coverage) }
    }

    /// Paints the palette's base colour; stripes are darkened on top afterwards.
    private static func fillPainter(_ fill: LogoFill, boxRect: CGRect) throws -> (CGContext, CGRect) -> Void {
        switch fill {
        case .solid(let color):
            return { ctx, rect in ctx.setFillColor(color.cgColor()); ctx.fill(rect) }
        case .rainbow:
            return { ctx, rect in ctx.setFillColor(RGB.white.cgColor()); ctx.fill(rect) }
        case .vertical(let stops):
            let gradient = try verticalGradient(stops)
            let top = CGPoint(x: boxRect.midX, y: boxRect.maxY), bottom = CGPoint(x: boxRect.midX, y: boxRect.minY)
            return { ctx, _ in
                ctx.drawLinearGradient(gradient, start: top, end: bottom,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
    }

    private static func verticalGradient(_ stops: [RGB]) throws -> CGGradient {
        let locations = stops.indices.map { CGFloat($0) / CGFloat(max(1, stops.count - 1)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: stops.map { $0.cgColor() } as CFArray,
                                        locations: locations)
        else { throw RenderError("cannot build the logo gradient") }
        return gradient
    }

    /// Alternating bright/dim rows imitate a striated CRT look. Translucent
    /// black keeps the stripes on top of any fill. The caller has already clipped to the coverage.
    private static func darkenAlternateRows(_ ctx: CGContext, bounds: CGRect, rowHeight: CGFloat) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1 - dimStripe))
        for y in stride(from: bounds.minY + rowHeight, to: bounds.maxY, by: rowHeight * 2) {
            ctx.fill(CGRect(x: bounds.minX, y: y, width: bounds.width, height: rowHeight))
        }
    }
}
