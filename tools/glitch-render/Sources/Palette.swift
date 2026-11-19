import CoreGraphics
import CoreImage
import Foundation

enum LogoFill {
    case solid(RGB)
    /// Evenly spaced stops from top to bottom.
    case vertical([RGB])
    /// Diagonal hue gradient that turns around the colour wheel during the loop.
    case rainbow
}

/// Every colour the renderer uses. The rainbow palette derives its HUD and streak colours
/// from the loop phase instead of the fixed `hud` / `streak` values.
struct Palette {
    let name: String
    let fill: LogoFill
    let glow: RGB
    let hud: RGB
    let streak: RGB
    let background: RGB

    static let defaultName = "green"
    private static let rainbowHUDSaturation: CGFloat = 0.35
    private static let rainbowHUDBrightness: CGFloat = 0.85
    private static let rainbowStreakSaturation: CGFloat = 0.3
    private static let noiseStreakMix: CGFloat = 0.4

    static let all: [Palette] = [
        solid("green", fill: 0x8CFFAE, glow: 0x2BFF6A, hud: 0x6ED08A, background: 0x000200),
        Palette(name: "purple", fill: .vertical([RGB(hex: 0xC46BFF), RGB(hex: 0x9B1BFF), RGB(hex: 0x4A0A86)]),
                glow: RGB(hex: 0x9B30FF), hud: RGB(hex: 0xB48CE6), streak: RGB(hex: 0xD2A6FF),
                background: RGB(hex: 0x020003)),
        Palette(name: "rgb", fill: .rainbow, glow: .white, hud: .white, streak: .white,
                background: RGB(hex: 0x020202)),
        solid("amber", fill: 0xFFC46B, glow: 0xFF9A1F, hud: 0xE0A65C, background: 0x030100),
        solid("cyan", fill: 0x8FF4FF, glow: 0x19D8FF, hud: 0x6CC9D6, background: 0x000203),
        solid("pink", fill: 0xFF8FD8, glow: 0xFF2FB4, hud: 0xE07CC0, background: 0x030002),
        solid("red", fill: 0xFF7A7A, glow: 0xFF2A2A, hud: 0xE06A6A, background: 0x030000),
    ]

    static var names: String { all.map(\.name).joined(separator: ", ") }

    static func named(_ name: String) throws -> Palette {
        guard let palette = all.first(where: { $0.name == name }) else {
            throw RenderError("unknown --palette \(name); valid palettes: \(names)")
        }
        return palette
    }

    var isRainbow: Bool {
        if case .rainbow = fill { return true }
        return false
    }

    /// One desaturated hue turn per loop for the rainbow palette, so it wraps seamlessly.
    func hudColor(phase: Double) -> RGB {
        guard isRainbow else { return hud }
        return RGB(hue: phase, saturation: Self.rainbowHUDSaturation, brightness: Self.rainbowHUDBrightness)
    }

    func streakColor(phase: Double) -> RGB {
        guard isRainbow else { return streak }
        return RGB(hue: phase, saturation: Self.rainbowStreakSaturation, brightness: 1)
    }

    /// Line noise and static: more saturated than the streaks, like green CRT interference.
    func noiseColor(phase: Double) -> RGB {
        isRainbow ? streakColor(phase: phase) : glow.mixed(toward: streak, Self.noiseStreakMix)
    }

    /// Streaks share the logo fill, as the green look does.
    private static func solid(_ name: String, fill: UInt32, glow: UInt32, hud: UInt32, background: UInt32) -> Palette {
        Palette(name: name, fill: .solid(RGB(hex: fill)), glow: RGB(hex: glow), hud: RGB(hex: hud),
                streak: RGB(hex: fill), background: RGB(hex: background))
    }
}

extension RGB {
    static let white = RGB(r: 1, g: 1, b: 1)

    /// HSV → RGB with `hue` in turns, so whole turns give the same colour.
    init(hue: Double, saturation: CGFloat, brightness: CGFloat) {
        let sector = (hue - floor(hue)) * 6
        let f = CGFloat(sector - floor(sector))
        let v = brightness, p = v * (1 - saturation)
        let q = v * (1 - saturation * f), t = v * (1 - saturation * (1 - f))
        let channels: [(CGFloat, CGFloat, CGFloat)] = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)]
        let (r, g, b) = channels[min(5, Int(sector))]
        self.init(r: r, g: g, b: b)
    }

    func mixed(toward other: RGB, _ amount: CGFloat) -> RGB {
        RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
    }
}

/// Diagonal rainbow built from one tiled hue strip. Sliding the strip by whole periods
/// rotates every hue, so `turnsPerLoop` periods per loop is both the animation and the seam.
struct HueField {
    private static let stripWidth = 360
    private static let turnsPerLoop: CGFloat = 2
    private static let saturation: CGFloat = 0.85
    private static let brightness: CGFloat = 1
    private static let angle = CGFloat.pi / 5

    private let tiled: CIImage
    private let period: CGFloat

    init(period: CGFloat) throws {
        let bytes = (0..<Self.stripWidth).flatMap { x -> [UInt8] in
            let color = RGB(hue: Double(x) / Double(Self.stripWidth), saturation: Self.saturation,
                            brightness: Self.brightness)
            return [color.r, color.g, color.b, 1].map { UInt8(($0 * 255).rounded()) }
        }
        tiled = try Raster.image(width: Self.stripWidth, height: 1, rgba: bytes).tiled()
        self.period = period
    }

    func image(phase: Double) -> CIImage {
        let shift = CGFloat(phase) * Self.turnsPerLoop * period
        let transform = CGAffineTransform(rotationAngle: Self.angle)
            .translatedBy(x: -shift, y: 0)
            .scaledBy(x: period / CGFloat(Self.stripWidth), y: 1)
        return tiled.transformed(by: transform)
    }
}
