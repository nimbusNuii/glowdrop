import CoreGraphics
import CoreImage
import Foundation

struct RenderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// SplitMix64 — tiny and reproducible, so every frame renders identically on every run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64, salt: UInt64 = 0) {
        state = (seed &* 0x9E37_79B9_7F4A_7C15) ^ (salt &* 0xBF58_476D_1CE4_E5B9)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func unit() -> CGFloat { CGFloat.random(in: 0..<1, using: &self) }
    mutating func range(_ bounds: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: bounds, using: &self) }
    mutating func int(_ bounds: ClosedRange<Int>) -> Int { Int.random(in: bounds, using: &self) }
    mutating func sign() -> CGFloat { Bool.random(using: &self) ? 1 : -1 }
}

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat

    init(hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }

    init(r: CGFloat, g: CGFloat, b: CGFloat) {
        self.r = r; self.g = g; self.b = b
    }

    func scaled(_ k: CGFloat) -> RGB { RGB(r: r * k, g: g * k, b: b * k) }
    func cgColor(alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}

enum Raster {
    /// Draws with CoreGraphics into `region` (canvas coordinates, origin bottom-left) and
    /// returns a CIImage already positioned at that region.
    static func draw(region: CGRect, _ body: (CGContext) -> Void) throws -> CIImage {
        let width = Int(region.width), height = Int(region.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError("cannot create \(width)x\(height) bitmap context") }
        ctx.translateBy(x: -region.minX, y: -region.minY)
        body(ctx)
        guard let image = ctx.makeImage() else { throw RenderError("cannot snapshot bitmap context") }
        return CIImage(cgImage: image).transformed(by: .init(translationX: region.minX, y: region.minY))
    }

    /// Builds an image from premultiplied RGBA8 bytes (row 0 = top).
    static func image(width: Int, height: Int, rgba: [UInt8]) throws -> CIImage {
        guard rgba.count == width * height * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { throw RenderError("cannot build \(width)x\(height) texture") }
        return CIImage(cgImage: image)
    }

    /// Renders a (possibly expensive) CI graph once so later frames reuse plain pixels.
    static func bake(_ image: CIImage, context: CIContext) throws -> CIImage {
        let rect = image.extent.integral
        guard !rect.isInfinite, !rect.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: space)
        else { throw RenderError("cannot bake image with extent \(rect)") }
        return CIImage(cgImage: cg).transformed(by: .init(translationX: rect.minX, y: rect.minY))
    }
}
