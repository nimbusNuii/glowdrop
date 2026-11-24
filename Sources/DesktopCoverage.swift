import CoreGraphics

/// Which displays windows hide completely, from the window list's bounds, layer and alpha only. Pure, so the
/// selftests cover it.
enum DesktopCoverage {
    struct Window: Equatable {
        let bounds: CGRect
        let layer: Int
        let alpha: Double
    }

    private static let normalLayer = 0
    private static let opaqueAlpha = 0.99
    private static let menuBarLayers: Set<Int> = [Int(CGWindowLevelForKey(.mainMenuWindow)),
                                                  Int(CGWindowLevelForKey(.statusWindow))]

    /// A display is covered when opaque normal-layer windows together cover all of its bounds: in practice a
    /// full-screen app, or windows that also cover the menu bar strip, as with the window engine's occlusion.
    /// `topInsets` (missing: 0) are the camera housings' safe-area insets: a full-screen app's window starts below
    /// one, and its Space hides the menu bar, so that strip is black and needs covering only while a menu bar shows.
    static func coveredDisplays(windows: [Window], displays: [UInt32: CGRect],
                                topInsets: [UInt32: CGFloat]) -> [UInt32] {
        let opaque = windows.filter { $0.layer == normalLayer && $0.alpha >= opaqueAlpha && !$0.bounds.isEmpty }
            .map(\.bounds)
        let menuBars = windows.filter { menuBarLayers.contains($0.layer) }.map(\.bounds)
        return displays.filter { id, bounds in
            isCovered(wallpaperArea(bounds, topInset: topInsets[id] ?? 0, menuBars: menuBars), by: opaque)
        }.keys.sorted()
    }

    /// The display, less the strip above its camera housing while no menu bar window shows over that strip.
    private static func wallpaperArea(_ display: CGRect, topInset: CGFloat, menuBars: [CGRect]) -> CGRect {
        let strip = CGRect(x: display.minX, y: display.minY, width: display.width, height: topInset)
        guard topInset > 0, !menuBars.contains(where: { !$0.intersection(strip).isEmpty }) else { return display }
        return CGRect(x: display.minX, y: strip.maxY, width: display.width, height: display.height - topInset)
    }

    private static func isCovered(_ display: CGRect, by windows: [CGRect]) -> Bool {
        windows.reduce([display]) { uncovered, window in uncovered.flatMap { subtract(window, from: $0) } }.isEmpty
    }

    /// What is left of `rect` outside `hole`: up to four rectangles.
    private static func subtract(_ hole: CGRect, from rect: CGRect) -> [CGRect] {
        let cut = rect.intersection(hole)
        guard !cut.isEmpty else { return [rect] }
        return [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
            CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
            CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height),
        ].filter { !$0.isEmpty }
    }
}
