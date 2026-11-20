// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.
//
// When a surface may decode video, and what a new read of the folder changes. Pure (no AVFoundation), so the
// selftests cover it.

import Foundation

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

/// System-wide signals: loginwindow's lock, the screen saver, display sleep, power and heat.
struct ScreenState: Equatable, Sendable {
    var screenLocked = false
    var screenSaverRunning = false
    var displaysAsleep = false
    var lowPowerMode = false
    var onBattery = false
    /// ProcessInfo's thermal state is serious or critical.
    var thermalHigh = false
}

/// Which video one surface shows: the tile picked for it in System Settings, read from the choice's `configuration`.
enum WallpaperChoice: Equatable, Sendable {
    /// Whatever the app plays (state.json).
    case follow
    /// One catalog video, by its file name in the LockScreen folder.
    case video(String)

    static let followID = "glowdrop"

    /// Only a name the app would write picks a video; anything else (nil, the follow tile, a path) follows the app.
    init(configuration: String?) {
        guard let configuration, LockScreenFiles.isVideoName(configuration) else {
            self = .follow
            return
        }
        self = .video(configuration)
    }
}

enum LockScreenPlayback {
    /// Never in the Settings preview, with the displays asleep, on a suspended surface, while the app is paused, under
    /// the power rules the app's settings turn on, or when the Mac runs hot. Otherwise video decodes on the lock screen
    /// and under the screen saver, and on the desktop only when the app plays there too; elsewhere the surface holds a
    /// still frame. As in Phosphene, loginwindow's lock counts before the agent's own `locked` update arrives, and
    /// `idle` is the screen-saver presentation.
    static func shouldDecode(_ surface: SurfacePresentation, _ screen: ScreenState, _ flags: PlaybackFlags) -> Bool {
        guard !surface.isPreview, !screen.displaysAsleep, surface.activity != .suspended, !flags.paused,
              !(screen.lowPowerMode && flags.pauseInLowPowerMode), !(screen.onBattery && flags.pauseOnBattery),
              !screen.thermalHigh else { return false }
        let lockOrScreenSaver = screen.screenLocked || screen.screenSaverRunning
            || surface.mode == .locked || surface.mode == .idle
        return lockOrScreenSaver || (surface.mode == .desktop && flags.desktop)
    }

    /// A new app video or catalog re-points the surfaces it affects; flags alone change nothing here. Same file with
    /// a new `updated`: the app copied it again, so players reading the old copy start over.
    static func change(from oldState: LockScreenState?, oldURL: URL?, oldCatalog: WallpaperCatalog?,
                       to state: LockScreenState?, url: URL?, catalog: WallpaperCatalog?)
        -> (followChanged: Bool, catalogChanged: Bool, refreshFollowVideo: Bool) {
        let updatedChanged = state?.updated != oldState?.updated
        let followChanged = state?.file != oldState?.file || updatedChanged || url != oldURL
        let refresh = url != nil && url == oldURL && updatedChanged
        return (followChanged, catalog != oldCatalog, refresh)
    }
}
