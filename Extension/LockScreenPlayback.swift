// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.
//
// When a surface may decode video. Pure (no AVFoundation), so the selftests cover it.

/// How WallpaperAgent presents one surface, from the `presentationMode` of an `update`.
enum PresentationMode: Equatable, Sendable {
    case desktop, locked, idle, other

    /// The agent's enum case name, read through Mirror.
    init(caseName: String) {
        switch caseName {
        case "default": self = .desktop
        case "locked": self = .locked
        case "idle": self = .idle
        default: self = .other
        }
    }
}

/// Whether the agent composites one surface, from the `activityState` of an `update`.
enum ActivityState: Equatable, Sendable {
    case active, suspended, other

    init(caseName: String) {
        if caseName == "active" {
            self = .active
        } else if caseName.contains("suspended") {
            self = .suspended
        } else {
            self = .other
        }
    }
}

struct SurfacePresentation: Equatable, Sendable {
    var isPreview: Bool
    var mode = PresentationMode.desktop
    var activity = ActivityState.active
}

/// System-wide signals: loginwindow's lock, the screen saver, display sleep.
struct ScreenState: Equatable, Sendable {
    var screenLocked = false
    var screenSaverRunning = false
    var displaysAsleep = false
}

enum LockScreenPlayback {
    /// Video decodes only on the lock screen or under the screen saver; everywhere else, and always in the
    /// Settings preview, the surface holds a still frame. As in Phosphene, loginwindow's lock counts before
    /// the agent's own `locked` update arrives, and `idle` is the screen-saver presentation.
    static func shouldDecode(_ surface: SurfacePresentation, _ screen: ScreenState) -> Bool {
        guard !surface.isPreview, !screen.displaysAsleep, surface.activity != .suspended else { return false }
        return screen.screenLocked || screen.screenSaverRunning || surface.mode == .locked || surface.mode == .idle
    }
}
