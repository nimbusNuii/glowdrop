import AppKit
import CoreGraphics

/// Tells the wallpaper extension which displays windows cover, for the system engine: it has no windows of its own
/// whose occlusion could say so. Reads only bounds, layer and alpha from the window list, never titles or owners.
@MainActor
final class DesktopCoverageMonitor {
    /// Sorted; empty while inactive.
    private(set) var coveredDisplays: [UInt32] = []
    /// Called once `coveredDisplays` changed while active; not by `setActive`, whose caller reads the list itself.
    var onChange: (@MainActor () -> Void)?
    private var isActive = false
    /// While the displays sleep or another session is in front nothing polls and the list keeps its last value, so
    /// sleep itself never reads as a coverage change; the extension decodes nothing while the displays sleep anyway.
    private var screensAsleep = false
    private var sessionInactive = false
    private var timer: Timer?

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        let signals: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (workspace, NSWorkspace.didActivateApplicationNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
        ]
        // The monitor lives as long as the app, so the tokens are not kept.
        for (center, name) in signals {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let pauses = [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                      NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pauses {
            _ = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseChanged(name) }
            }
        }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        updateTimer()
        coveredDisplays = active ? Self.currentCoveredDisplays() : []
    }

    /// Waking or coming back to the front evaluates at once; a change found then is a real one.
    private func pauseChanged(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        default: sessionInactive = false
        }
        updateTimer()
        refresh()
    }

    /// Polls only while active, with the displays awake and this session in front.
    private func updateTimer() {
        let polls = isActive && !screensAsleep && !sessionInactive
        guard polls != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard polls else { return }
        // shortcut: a 2 s poll also catches window moves and resizes, which post no notification; upgrade if a
        // window-server change notification ever becomes public.
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        self.timer = timer
    }

    private func refresh() {
        guard timer != nil else { return }
        let covered = Self.currentCoveredDisplays()
        guard covered != coveredDisplays else { return }
        coveredDisplays = covered
        onChange?()
    }

    /// Unreadable displays or windows count as uncovered, so the wallpaper keeps playing.
    private static func currentCoveredDisplays() -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let displays = Dictionary(ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) },
                                  uniquingKeysWith: { first, _ in first })
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let windows = (list as? [[String: Any]] ?? []).compactMap(window)
        return DesktopCoverage.coveredDisplays(windows: windows, displays: displays, topInsets: topInsets())
    }

    /// Each display's camera-housing inset; a display NSScreen does not list gets none.
    private static func topInsets() -> [UInt32: CGFloat] {
        let insets = NSScreen.screens.compactMap { screen -> (UInt32, CGFloat)? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                .map { ($0, screen.safeAreaInsets.top) }
        }
        return Dictionary(insets, uniquingKeysWith: { first, _ in first })
    }

    private static func window(_ info: [String: Any]) -> DesktopCoverage.Window? {
        guard let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
              let layer = info[kCGWindowLayer as String] as? Int,
              let alpha = info[kCGWindowAlpha as String] as? Double else { return nil }
        return DesktopCoverage.Window(bounds: bounds, layer: layer, alpha: alpha)
    }
}
