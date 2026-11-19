// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.

import ExtensionFoundation
import Foundation

/// The com.apple.wallpaper extension: shows the video Glowdrop mirrors into
/// ~/Library/Application Support/Glowdrop/LockScreen on the lock screen (macOS 26+).
@main
final class GlowdropWallpaperExtension: NSObject, AppExtension {
    private static let wallpaperKitPath =
        "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"

    override required init() {
        super.init()
        // The handle stays open for the process lifetime: the XPC value classes live there.
        guard dlopen(Self.wallpaperKitPath, RTLD_LAZY) != nil else {
            wallpaperLog("INIT pid=\(getpid()) dlopen WallpaperExtensionKit FAILED:",
                         privateDetail: dlerror().map { String(cString: $0) } ?? "unknown error")
            return
        }
        wallpaperLog("INIT pid=\(getpid()) WallpaperExtensionKit loaded")
        verifyRuntimeLayout()
        DispatchQueue.main.async { MainActor.assumeIsolated { SurfaceStore.shared.start() } }
    }

    var configuration: some AppExtensionConfiguration {
        WallpaperExtensionConfig()
    }
}
