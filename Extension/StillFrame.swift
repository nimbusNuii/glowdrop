// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.
//
// Still frames: what every surface shows while it is not decoding.

import AVFoundation
import CoreMedia
import CoreVideo

/// The largest still decoded (4K UHD): an 8K video's first frame would otherwise hold ~130 MB per copy.
let maxStillSize = CGSize(width: 3_840, height: 2_160)

/// The video's first frame scaled to fit `maxSize` (aspect kept), or nil (logged) when it can't be read, or when
/// `timeout` passes first (the generation is cancelled).
func firstFrame(of url: URL, maxSize: CGSize = maxStillSize, timeout: Duration? = nil) async -> CGImage? {
    let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey:
                                                   AVAssetReferenceRestrictions.forbidAll.rawValue])
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maxSize
    // Not Sendable, but cancelAllCGImageGeneration exists to be called while a generation runs elsewhere.
    nonisolated(unsafe) let cancellable = generator
    let timer = timeout.map { limit in
        Task {
            try await Task.sleep(for: limit)
            cancellable.cancelAllCGImageGeneration()
        }
    }
    defer { timer?.cancel() }
    do {
        return try await generator.image(at: .zero).image
    } catch {
        wallpaperLog("[Still] first frame of \(url.lastPathComponent) failed:", privateDetail: error.localizedDescription)
        return nil
    }
}

/// `image` in an IOSurface-backed sample buffer at PTS zero, marked display-immediately. Unlike CALayer.contents
/// (black when hosted cross-process) it composites into WallpaperAgent's CALayerHost.
func makeStillSampleBuffer(from image: CGImage) -> CMSampleBuffer? {
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    var pixelBufferOut: CVPixelBuffer?
    guard image.width > 0, image.height > 0,
          CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                              attributes as CFDictionary, &pixelBufferOut) == kCVReturnSuccess,
          let pixelBuffer = pixelBufferOut, draw(image, into: pixelBuffer) else { return nil }

    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format
    ) == noErr, let format else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &sample
    ) == noErr, let sample else { return nil }
    setDisplayImmediately(sample)
    return sample
}

private func draw(_ image: CGImage, into pixelBuffer: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer), width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return true
}

/// Shows the sample as soon as it is enqueued, whatever the control timebase says (it may be stopped).
func setDisplayImmediately(_ sample: CMSampleBuffer) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
    for index in 0..<CFArrayGetCount(attachments) {
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, index), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
