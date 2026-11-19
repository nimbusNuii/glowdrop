import CoreGraphics
import CoreImage
import CoreText
import Foundation

struct HUDAssets {
    let staticLayer: CIImage
    /// One pre-glowed image of the loading squares per bright-square position.
    let dotStates: [CIImage]
}

struct HUDText {
    let title: String
    let subtitle: String
    let caption: String
}

/// Layout values are fractions of the canvas, y measured from the top.
enum HUDRenderer {
    /// Drawn white and tinted per frame, so palettes (and the cycling rainbow) reuse one bake.
    private static let color = RGB.white
    private static let alpha: CGFloat = 0.85
    private static let dimDotAlpha: CGFloat = 0.35
    private static let fontName = "Menlo-Bold"

    private struct Layout {
        let canvas: CGSize
        let capHeight: CGFloat
        let font: CTFont
        let smallFont: CTFont
        let text: HUDText

        func x(_ fraction: CGFloat) -> CGFloat { canvas.width * fraction }
        /// Converts a top-down fraction to a bottom-up CG y coordinate.
        func y(_ fraction: CGFloat) -> CGFloat { canvas.height * (1 - fraction) }
    }

    static func make(canvas: CGSize, context: CIContext, text: HUDText) throws -> HUDAssets {
        let layout = try makeLayout(canvas: canvas, text: text)
        let sigma = canvas.height * 0.003
        let full = CGRect(origin: .zero, size: canvas)
        let staticCrisp = try Raster.draw(region: full) { ctx in drawStatic(ctx, layout) }
        let staticLayer = try glowed(staticCrisp, sigma: sigma, context: context)
        let dotRegion = dotRects(layout).reduce(CGRect.null) { $0.union($1) }
            .insetBy(dx: -sigma * 4, dy: -sigma * 4).integral
        let dotStates = try (0..<Timeline.dotCount).map { bright in
            let crisp = try Raster.draw(region: dotRegion) { ctx in drawDots(ctx, layout, bright: bright) }
            return try glowed(crisp, sigma: sigma, context: context)
        }
        return HUDAssets(staticLayer: staticLayer, dotStates: dotStates)
    }

    private static func makeLayout(canvas: CGSize, text: HUDText) throws -> Layout {
        let probe = CTFontCreateWithName(fontName as CFString, 100, nil)
        guard CTFontCopyPostScriptName(probe) as String == fontName else {
            throw RenderError("font \(fontName) is not installed")
        }
        let capHeight = canvas.height * 0.020
        let size = capHeight / (CTFontGetCapHeight(probe) / 100)
        return Layout(canvas: canvas, capHeight: capHeight,
                      font: CTFontCreateWithName(fontName as CFString, size, nil),
                      smallFont: CTFontCreateWithName(fontName as CFString, size * 0.85, nil), text: text)
    }

    /// Crisp layer over a faint blurred copy of itself; baked so frames reuse pixels.
    private static func glowed(_ crisp: CIImage, sigma: CGFloat, context: CIContext) throws -> CIImage {
        let glow = crisp.applyingGaussianBlur(sigma: sigma).opacity(0.35)
        return try Raster.bake(crisp.composited(over: glow).cropped(to: crisp.extent), context: context)
    }

    private static func drawStatic(_ ctx: CGContext, _ layout: Layout) {
        ctx.setFillColor(color.cgColor(alpha: alpha))
        ctx.setStrokeColor(color.cgColor(alpha: alpha))
        drawTitle(ctx, layout)
        drawSlashes(ctx, layout)
        drawLocation(ctx, layout)
    }

    private static func drawTitle(_ ctx: CGContext, _ layout: Layout) {
        let cap = layout.capHeight
        let baseline = layout.y(0.135)
        let left = layout.x(0.075)
        let triangleWidth = cap * 0.85
        ctx.addLines(between: [CGPoint(x: left, y: baseline), CGPoint(x: left, y: baseline + cap),
                               CGPoint(x: left + triangleWidth, y: baseline + cap / 2)])
        ctx.closePath()
        ctx.fillPath()
        let textX = left + triangleWidth + cap * 0.8
        // A long title shrinks to stop short of the slashes instead of running into them.
        let font = fitted(layout.font, layout.text.title, kernEm: 0.12,
                          maxWidth: slashesLeft(layout) - cap * 1.5 - textX)
        drawText(ctx, layout.text.title, font: font, kernEm: 0.12, at: CGPoint(x: textX, y: baseline))
    }

    private static func slashMetrics(_ layout: Layout) -> (height: CGFloat, barWidth: CGFloat, slant: CGFloat, pitch: CGFloat) {
        let height = layout.canvas.height * 0.028
        let barWidth = layout.x(0.009)
        return (height, barWidth, height * 0.5, barWidth + layout.x(0.0045))
    }

    private static func slashesLeft(_ layout: Layout) -> CGFloat {
        let m = slashMetrics(layout)
        return layout.x(0.925) - 2 * m.pitch - m.slant - m.barWidth
    }

    /// Three "/" parallelograms, right-aligned, vertically centred on the title's caps.
    private static func drawSlashes(_ ctx: CGContext, _ layout: Layout) {
        let (height, barWidth, slant, pitch) = slashMetrics(layout)
        let bottom = layout.y(0.135) + layout.capHeight / 2 - height / 2
        for index in 0..<3 {
            let topRight = layout.x(0.925) - CGFloat(index) * pitch
            ctx.addLines(between: [
                CGPoint(x: topRight - slant - barWidth, y: bottom), CGPoint(x: topRight - slant, y: bottom),
                CGPoint(x: topRight, y: bottom + height), CGPoint(x: topRight - barWidth, y: bottom + height),
            ])
            ctx.closePath()
        }
        ctx.fillPath()
    }

    private static func drawLocation(_ ctx: CGContext, _ layout: Layout) {
        let arm = layout.canvas.height * 0.018
        let thickness = max(1, (layout.canvas.height * 0.0016).rounded())
        let center = CGPoint(x: layout.x(0.075) + arm, y: layout.y(0.84))
        ctx.fill(CGRect(x: center.x - arm, y: center.y - thickness / 2, width: arm * 2, height: thickness))
        ctx.fill(CGRect(x: center.x - thickness / 2, y: center.y - arm, width: thickness, height: arm * 2))
        let left = layout.x(0.105)
        // Keep the location text clear of the loading squares on the right.
        let maxWidth = (dotRects(layout).first?.minX ?? layout.canvas.width) - layout.capHeight * 2 - left
        drawText(ctx, layout.text.subtitle, font: fitted(layout.font, layout.text.subtitle, kernEm: 0.08, maxWidth: maxWidth),
                 kernEm: 0.08, at: CGPoint(x: left, y: layout.y(0.835)))
        drawText(ctx, layout.text.caption, font: fitted(layout.smallFont, layout.text.caption, kernEm: 0.06, maxWidth: maxWidth),
                 kernEm: 0.06, at: CGPoint(x: left, y: layout.y(0.865)))
    }

    private static func dotRects(_ layout: Layout) -> [CGRect] {
        let size = (layout.canvas.height * 0.006).rounded()
        let gap = (layout.canvas.height * 0.009).rounded()
        let right = layout.x(0.925).rounded()
        let bottom = layout.y(0.86).rounded()
        return (0..<Timeline.dotCount).map { index in
            let fromRight = CGFloat(Timeline.dotCount - index)
            let x = right - fromRight * size - (fromRight - 1) * gap
            return CGRect(x: x, y: bottom, width: size, height: size)
        }
    }

    private static func drawDots(_ ctx: CGContext, _ layout: Layout, bright: Int) {
        for (index, rect) in dotRects(layout).enumerated() {
            let dotAlpha = index == bright ? alpha : alpha * dimDotAlpha
            ctx.setFillColor(color.cgColor(alpha: dotAlpha))
            ctx.fill(rect)
        }
    }

    private static func makeLine(_ text: String, font: CTFont, kernEm: CGFloat) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor(alpha: alpha),
            NSAttributedString.Key(kCTKernAttributeName as String): CTFontGetSize(font) * kernEm,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// `font` scaled down (never up) so `text` fits in `maxWidth`; kerning scales with the font size.
    private static func fitted(_ font: CTFont, _ text: String, kernEm: CGFloat, maxWidth: CGFloat) -> CTFont {
        let width = CTLineGetTypographicBounds(makeLine(text, font: font, kernEm: kernEm), nil, nil, nil)
        guard maxWidth > 0, width > maxWidth else { return font }
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * maxWidth / width, nil, nil)
    }

    private static func drawText(_ ctx: CGContext, _ text: String, font: CTFont, kernEm: CGFloat, at origin: CGPoint) {
        let line = makeLine(text, font: font, kernEm: kernEm)
        ctx.textMatrix = .identity
        ctx.textPosition = origin
        CTLineDraw(line, ctx)
    }
}
