import Foundation

struct RenderOptions {
    let outPath: String?
    let width: Int
    let height: Int
    let fps: Int
    let seconds: Int
    let bitrate: Int
    let stillFrame: Int?
    let pngPath: String?
    let logoMask: LogoMask
    let hudText: HUDText
    let palette: Palette

    static let usage = """
        usage: glitch-render --out <file.mp4> [--width 3840] [--height 2400] [--fps 60] [--seconds 12]
                          [--bitrate 30000000] [--still <frameIndex> --png <file.png>]
                          [--logo-text <TEXT> | --logo-mask <mask.png>] [--logo-height 0.40]
                          [--hud-title <TEXT>] [--hud-subtitle <TEXT>] [--hud-caption <TEXT>]
                          [--palette \(Palette.all.map(\.name).joined(separator: "|"))]
        """

    private static let knownFlags: Set<String> = [
        "--out", "--width", "--height", "--fps", "--seconds", "--bitrate", "--still", "--png",
        "--logo-mask", "--logo-height", "--palette", "--logo-text", "--hud-title", "--hud-subtitle", "--hud-caption",
    ]
    private static let maxTextLength = 40
    private static let maxDimension = 8192
    private static let maxFPS = 240
    private static let maxSeconds = 600
    private static let maxBitrate = 200_000_000

    var isStill: Bool { stillFrame != nil }

    static func parse(_ arguments: [String]) throws -> RenderOptions {
        let values = try pairs(arguments)
        let options = RenderOptions(
            outPath: values["--out"],
            width: try positive(values, "--width", default: 3840),
            height: try positive(values, "--height", default: 2400),
            fps: try positive(values, "--fps", default: 60),
            seconds: try positive(values, "--seconds", default: 12),
            bitrate: try positive(values, "--bitrate", default: 30_000_000),
            stillFrame: try values["--still"].map { try integer($0, flag: "--still") },
            pngPath: values["--png"],
            logoMask: try logoMask(values),
            hudText: HUDText(title: try text(values, "--hud-title", default: "LIVE WALLPAPER"),
                             subtitle: try text(values, "--hud-subtitle", default: "OPEN SOURCE"),
                             caption: try text(values, "--hud-caption", default: "MIT LICENSE · 60 FPS")),
            palette: try Palette.named(values["--palette"] ?? Palette.defaultName))
        try options.validate()
        return options
    }

    private func validate() throws {
        guard width % 2 == 0, height % 2 == 0, width <= Self.maxDimension, height <= Self.maxDimension else {
            throw RenderError("--width/--height must be even and at most \(Self.maxDimension)")
        }
        guard fps <= Self.maxFPS else { throw RenderError("--fps must be at most \(Self.maxFPS)") }
        guard seconds <= Self.maxSeconds else { throw RenderError("--seconds must be at most \(Self.maxSeconds)") }
        guard bitrate <= Self.maxBitrate else { throw RenderError("--bitrate must be at most \(Self.maxBitrate)") }
        if let stillFrame {
            guard outPath == nil else { throw RenderError("--out cannot be used with --still (use --png)") }
            guard let pngPath else { throw RenderError("--still requires --png <file.png>") }
            guard (0..<(fps * seconds)).contains(stillFrame) else {
                throw RenderError("--still must be in 0..<\(fps * seconds)")
            }
            try Self.checkWritable(pngPath)
            return
        }
        guard pngPath == nil else { throw RenderError("--png requires --still <frameIndex>") }
        guard let outPath else { throw RenderError("--out <file.mp4> is required") }
        try Self.checkWritable(outPath)
    }

    private static func pairs(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count % 2 == 0 else { throw RenderError("every flag needs a value") }
        return try stride(from: 0, to: arguments.count, by: 2).reduce(into: [:]) { values, index in
            let flag = arguments[index]
            guard knownFlags.contains(flag) else { throw RenderError("unknown flag \(flag)") }
            guard values[flag] == nil else { throw RenderError("duplicate flag \(flag)") }
            values[flag] = arguments[index + 1]
        }
    }

    private static func logoMask(_ values: [String: String]) throws -> LogoMask {
        var height = LogoMask.defaultHeight
        if let text = values["--logo-height"] {
            guard let value = Double(text), LogoMask.heightRange.contains(CGFloat(value)) else {
                throw RenderError("--logo-height must be a number in \(LogoMask.heightRange)")
            }
            height = CGFloat(value)
        }
        if let path = values["--logo-mask"] { return try LogoMask.load(path: path, heightFraction: height) }
        return try LogoMask.text(try text(values, "--logo-text", default: "GLOWDROP"), heightFraction: height)
    }

    /// Trimmed flag value (or the default); 1...maxTextLength characters.
    private static func text(_ values: [String: String], _ flag: String, default fallback: String) throws -> String {
        let value = values[flag]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
        guard !value.isEmpty, value.count <= maxTextLength else {
            throw RenderError("\(flag) must be 1 to \(maxTextLength) characters (after trimming)")
        }
        return value
    }

    private static func integer(_ text: String, flag: String) throws -> Int {
        guard let value = Int(text), value >= 0 else { throw RenderError("\(flag) must be a non-negative integer") }
        return value
    }

    private static func positive(_ values: [String: String], _ flag: String, default fallback: Int) throws -> Int {
        guard let text = values[flag] else { return fallback }
        guard let value = Int(text), value > 0 else { throw RenderError("\(flag) must be a positive integer") }
        return value
    }

    private static func checkWritable(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RenderError("output directory does not exist: \(directory)")
        }
        guard FileManager.default.isWritableFile(atPath: directory) else {
            throw RenderError("output directory is not writable: \(directory)")
        }
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard !(exists && isDirectory.boolValue) else { throw RenderError("output path is a directory: \(path)") }
    }
}
