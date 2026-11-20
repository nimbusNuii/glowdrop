// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.

import CoreGraphics
import Foundation
@preconcurrency import IOSurface

/// A WallpaperSnapshotXPC (IOSurface) holding the first frame of surface `key`'s video (else of the app's video),
/// or the neutral dark image.
@MainActor
func makeSnapshotXPC(for key: UUID?) async -> AnyObject? {
    guard let image = await SurfaceStore.shared.stillImage(for: key) ?? makeSolidImage(neutralDark, width: 1_920, height: 1_080)
    else {
        wallpaperLog("[Snapshot] no image")
        return nil
    }
    return renderToSnapshotXPC(image: image)
}

private func renderToSnapshotXPC(image: CGImage) -> AnyObject? {
    let props: [IOSurfacePropertyKey: any Sendable] = [
        .width: image.width,
        .height: image.height,
        .bytesPerElement: 4,
        .pixelFormat: 0x4247_5241, // 'BGRA'
    ]
    guard let surface = IOSurface(properties: props) else {
        wallpaperLog("[Snapshot] IOSurface creation failed")
        return nil
    }
    surface.lock(options: [], seed: nil)
    defer { surface.unlock(options: [], seed: nil) }
    guard let ctx = CGContext(
        data: surface.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: surface.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        wallpaperLog("[Snapshot] CGContext over IOSurface failed")
        return nil
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return createSnapshotXPC(surface: surface)
}
