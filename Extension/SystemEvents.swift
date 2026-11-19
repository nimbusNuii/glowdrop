// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.

import AppKit
import CoreGraphics

/// Turns loginwindow lock/unlock, the screen saver and display sleep into `ScreenState` changes.
/// loginwindow reports the lock before WallpaperAgent updates any surface, so the lock screen starts
/// playing without waiting for the agent.
@MainActor
enum SystemEvents {
    static func start(_ store: SurfaceStore) {
        store.updateScreen { $0.screenLocked = isScreenLockedNow() }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        let signals: [(NotificationCenter, Notification.Name, @Sendable (inout ScreenState) -> Void)] = [
            (distributed, .init("com.apple.screenIsLocked"), { $0.screenLocked = true }),
            (distributed, .init("com.apple.screenIsUnlocked"), { $0.screenLocked = false }),
            (distributed, .init("com.apple.screensaver.didstart"), { $0.screenSaverRunning = true }),
            (distributed, .init("com.apple.screensaver.didstop"), { $0.screenSaverRunning = false }),
            (workspace, NSWorkspace.screensDidSleepNotification, { $0.displaysAsleep = true }),
            (workspace, NSWorkspace.screensDidWakeNotification, { $0.displaysAsleep = false }),
        ]
        // The observers live as long as the process, so their tokens are not kept.
        for (center, name, change) in signals {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { store.updateScreen(change) }
            }
        }
    }

    /// The lock state at launch: the agent may start this process for a screen that is already locked.
    private static func isScreenLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
