import AppKit
import AVFoundation
import ImageIO

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage?

    /// Keyed by file path; bounded, and NSCache also drops entries under memory pressure.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()
    private static let frameSize = CGSize(width: 640, height: 360)
    private nonisolated static let thumbMaxPixelSize = 640

    /// Uses the `-thumb` sidecar when there is one and it decodes, otherwise a frame at 1 s of the video.
    /// A failed thumbnail keeps the placeholder icon; the wallpaper itself is unaffected.
    func load(image imageURL: URL?, video videoURL: URL?) async {
        guard let source = imageURL ?? videoURL else { return }
        let key = source.path as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }
        var loaded: NSImage?
        if let imageURL { loaded = await Self.readImage(imageURL) }
        if loaded == nil, let videoURL { loaded = await Self.frame(of: videoURL) }
        guard let loaded else { return }
        Self.cache.setObject(loaded, forKey: key)
        image = loaded
    }

    /// Decodes a downscaled copy off the main thread instead of the full-size image.
    private static func readImage(_ url: URL) async -> NSImage? {
        let thumb = await Task.detached { decodeThumbnail(url) }.value
        return thumb.map { NSImage(cgImage: $0, size: .zero) }
    }

    private nonisolated static func decodeThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbMaxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func frame(of url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey:
                                                       AVAssetReferenceRestrictions.forbidAll.rawValue])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = frameSize
        guard let result = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else {
            return nil
        }
        return NSImage(cgImage: result.image, size: .zero)
    }
}
