import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// A grayscale logo mask (white = glowing): a PNG from disk or rendered text.
struct LogoMask {
    static let heightRange: ClosedRange<CGFloat> = 0.1...0.9
    static let defaultHeight: CGFloat = 0.40
    private static let fontName = "Futura-CondensedExtraBold"
    private static let capHeightPixels: CGFloat = 600
    private static let kernEm: CGFloat = 0.04
    private static let paddingPixels: CGFloat = 24

    let image: CGImage
    let heightFraction: CGFloat

    var aspect: CGFloat { CGFloat(image.width) / CGFloat(image.height) }

    static func load(path: String, heightFraction: CGFloat) throws -> LogoMask {
        guard FileManager.default.fileExists(atPath: path) else {
            throw RenderError("--logo-mask file does not exist: \(path)")
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RenderError("--logo-mask cannot be loaded as an image: \(path)") }
        guard image.width > 0, image.height > 0 else { throw RenderError("--logo-mask image has zero size: \(path)") }
        return LogoMask(image: image, heightFraction: heightFraction)
    }

    /// `text` drawn white on black, cropped to its glyph bounds plus a little padding.
    static func text(_ text: String, heightFraction: CGFloat) throws -> LogoMask {
        let probe = CTFontCreateWithName(fontName as CFString, 100, nil)
        guard CTFontCopyPostScriptName(probe) as String == fontName else {
            throw RenderError("font \(fontName) is not installed")
        }
        let size = capHeightPixels / (CTFontGetCapHeight(probe) / 100)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            NSAttributedString.Key(kCTKernAttributeName as String): size * kernEm,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let glyphs = CTLineGetImageBounds(line, nil)
        guard glyphs.width > 0, glyphs.height > 0 else { throw RenderError("logo text has no visible glyphs") }
        let width = Int((glyphs.width + paddingPixels * 2).rounded(.up))
        let height = Int((glyphs.height + paddingPixels * 2).rounded(.up))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw RenderError("cannot create \(width)x\(height) logo text context") }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: paddingPixels - glyphs.minX, y: paddingPixels - glyphs.minY)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage() else { throw RenderError("cannot snapshot logo text context") }
        return LogoMask(image: image, heightFraction: heightFraction)
    }

    /// The mask scaled into `rect` and rasterised over `bounds` as an 8-bit gray image (white = covered).
    func coverage(rect: CGRect, bounds: CGRect) throws -> CGImage {
        let width = Int(bounds.width), height = Int(bounds.height)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw RenderError("cannot create \(width)x\(height) mask context") }
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        guard let scaled = ctx.makeImage() else { throw RenderError("cannot snapshot mask context") }
        return scaled
    }
}
