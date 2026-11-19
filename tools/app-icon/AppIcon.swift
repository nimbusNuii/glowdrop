import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Glowdrop app icon, drawn in a 1024-unit space and scaled to the requested pixel size.

let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(red: r, green: g, blue: b, alpha: alpha)
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient? {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
}

let neon: UInt32 = 0x3DFFA2

func squirclePath() -> CGPath {
    CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
           cornerWidth: 185, cornerHeight: 185, transform: nil)
}

// Tip (512,800), circle centre (512,430) r 190; sides are tangent lines from the tip.
func dropPath() -> CGPath {
    let tip = CGPoint(x: 512, y: 800)
    let centre = CGPoint(x: 512, y: 430)
    let radius: CGFloat = 190
    let alpha = acos(radius / (tip.y - centre.y))
    let dx = radius * sin(alpha)
    let dy = radius * cos(alpha)
    let startAngle = atan2(dy, dx)
    let path = CGMutablePath()
    path.move(to: tip)
    path.addLine(to: CGPoint(x: centre.x + dx, y: centre.y + dy))
    path.addArc(center: centre, radius: radius, startAngle: startAngle,
                endAngle: .pi - startAngle, clockwise: true)
    path.closeSubpath()
    return path
}

func drawBands(_ ctx: CGContext, in rect: CGRect, height: CGFloat, pitch: CGFloat, alpha: CGFloat) {
    ctx.setFillColor(rgb(0x000000, alpha))
    var y = rect.minY
    while y < rect.maxY {
        ctx.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: height))
        y += pitch
    }
}

func drawBody(_ ctx: CGContext, scale: CGFloat, small: Bool) {
    let path = squirclePath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale,
                  color: rgb(0x000000, small ? 0.2 : 0.35))
    ctx.setFillColor(rgb(0x060807))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    if let gradient = linearGradient([rgb(0x161D19), rgb(0x060807)], [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924),
                               end: CGPoint(x: 0, y: 100), options: [])
    }
    if !small {
        drawBands(ctx, in: CGRect(x: 100, y: 100, width: 824, height: 824),
                  height: 3, pitch: 9, alpha: 0.22)
    }
    ctx.restoreGState()

    ctx.setStrokeColor(rgb(0xFFFFFF, 0.07))
    ctx.setLineWidth(2)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 101, y: 101, width: 822, height: 822),
                       cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.strokePath()
}

func drawGlow(_ ctx: CGContext, scale: CGFloat, small: Bool) {
    let blurs: [CGFloat] = small ? [30] : [70, 30]
    for blur in blurs {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur * scale, color: rgb(neon, small ? 0.6 : 0.85))
        ctx.setFillColor(rgb(neon))
        ctx.addPath(dropPath())
        ctx.fillPath()
        ctx.restoreGState()
    }
}

func drawSpecular(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: 440, y: 520)
    ctx.rotate(by: -.pi / 6)
    ctx.scaleBy(x: 35, y: 75)
    if let gradient = linearGradient([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)], [0, 1]) {
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: 1, options: [])
    }
    ctx.restoreGState()
}

func drawDrop(_ ctx: CGContext, scale: CGFloat, size: Int) {
    drawGlow(ctx, scale: scale, small: size < 64)
    ctx.saveGState()
    ctx.addPath(dropPath())
    ctx.clip()
    let colors = [rgb(0x7DFFC4), rgb(neon), rgb(0x18C8A0)]
    if let gradient = linearGradient(colors, [0, 0.5, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 800),
                               end: CGPoint(x: 0, y: 240), options: [])
    }
    if size >= 64 {
        drawBands(ctx, in: CGRect(x: 300, y: 240, width: 424, height: 560),
                  height: 4, pitch: 12, alpha: 0.18)
    }
    drawSpecular(ctx)
    ctx.restoreGState()
}

func render(size: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.interpolationQuality = .high
    drawBody(ctx, scale: scale, small: size < 64)
    drawDrop(ctx, scale: scale, size: size)
    return ctx.makeImage()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\nusage: app-icon --size <16...1024> --out <file.png>\n".utf8))
    exit(1)
}

func parseArgs(_ args: [String]) -> (size: Int, out: String) {
    var size: Int?
    var out: String?
    var i = 0
    while i < args.count {
        guard i + 1 < args.count else { fail("missing value for \(args[i])") }
        switch args[i] {
        case "--size": size = Int(args[i + 1])
        case "--out": out = args[i + 1]
        default: fail("unknown argument \(args[i])")
        }
        i += 2
    }
    guard let size, (16...1024).contains(size) else { fail("--size must be an integer 16...1024") }
    guard let out, !out.isEmpty else { fail("--out is required") }
    var isDir: ObjCBool = false
    let dir = (out as NSString).deletingLastPathComponent
    let parent = dir.isEmpty ? "." : dir
    guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else {
        fail("output directory does not exist: \(parent)")
    }
    return (size, out)
}

let (size, out) = parseArgs(Array(CommandLine.arguments.dropFirst()))
guard let image = render(size: size) else { fail("could not create bitmap context") }
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fail("could not open \(out) for writing")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fail("could not write PNG to \(out)") }
