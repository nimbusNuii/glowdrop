// Logging, paths and the neutral fallback image shared by the wallpaper extension, which plays Glowdrop videos
// on the desktop and the lock screen.

import CoreGraphics
import Foundation
import ImageIO
import os

private let logger = Logger(subsystem: "io.github.nimbusnuii.glowdrop.wallpaper", category: "wallpaper")

/// Notice level so lines persist in `log show`. Messages carry file names and ids only, never full paths.
func wallpaperLog(_ message: String) {
    logger.notice("\(message, privacy: .public)")
}

/// For error descriptions and paths: `detail` is redacted unless private data logging is enabled.
func wallpaperLog(_ message: String, privateDetail detail: String) {
    logger.notice("\(message, privacy: .public) \(detail, privacy: .private)")
}

func wallpaperError(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "GlowdropWallpaper", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

enum WallpaperPaths {
    /// Sandboxed NSHomeDirectory() points into the container; the read-only home-relative
    /// exception is resolved against the real home.
    static let realHome: String = {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }()

    /// Written by the app (LockScreenSync); the only folder outside the container the extension may read.
    static let lockScreenDir = URL(fileURLWithPath: realHome)
        .appendingPathComponent("Library/Application Support/Glowdrop/LockScreen", isDirectory: true)

    /// The tile image, inside the extension's own container.
    static let thumbnailURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/thumbnail.png")

    /// One tile image per catalog video (`<file>.r<updated>.png`), inside the extension's own container.
    static let thumbnailsDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/Thumbnails", isDirectory: true)
}

/// Same dark grey as the app's gallery background; shown when there is no video to show.
let neutralDark = CGColor(gray: 0.07, alpha: 1)

func makeSolidImage(_ color: CGColor, width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

/// Written beside `url` under a hidden temporary name, then renamed over it, so the agent never reads half a PNG.
func writePNG(_ image: CGImage, to url: URL) -> Bool {
    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
    guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest), rename(temp.path, url.path) == 0 else {
        // The caller logs the failure; a temporary file that survives this is harmless and small.
        try? FileManager.default.removeItem(at: temp)
        return false
    }
    return true
}
