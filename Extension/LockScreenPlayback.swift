// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.
//
// When a surface may decode video, which clone of a catalog video it plays, which video Shuffle plays when, and what
// a new read of the folder changes. Pure (no AVFoundation), so the selftests cover it.

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
    /// The display the agent's acquire named; nil when it named none.
    var displayID: UInt32?
}

/// System-wide signals: loginwindow's lock, the screen saver, display sleep, power, heat and Reduce Motion.
struct ScreenState: Equatable, Sendable {
    var screenLocked = false
    var screenSaverRunning = false
    var displaysAsleep = false
    var lowPowerMode = false
    var onBattery = false
    /// ProcessInfo's thermal state is serious or critical.
    var thermalHigh = false
    /// ProcessInfo's thermal state is fair or worse.
    var thermalElevated = false
    /// Accessibility's Reduce Motion is on.
    var reduceMotion = false
}

/// Which video one surface shows: the tile picked for it in System Settings, read from the choice's `configuration`.
enum WallpaperChoice: Equatable, Sendable {
    /// Whatever the app plays (state.json).
    case follow
    /// A catalog video that changes every `PlaybackFlags.shuffleInterval` (see `LockScreenPlayback.shuffleIndex`).
    case shuffle
    /// One catalog video, by its file name in the LockScreen folder.
    case video(String)

    static let followID = "glowdrop"
    /// No file extension, so never a name `LockScreenFiles.isVideoName` accepts.
    static let shuffleID = "shuffle"

    /// Shuffle's id picks Shuffle, and only a name the app would write picks a video; anything else (nil, the follow
    /// tile, a path) follows the app.
    init(configuration: String?) {
        if configuration == Self.shuffleID {
            self = .shuffle
            return
        }
        guard let configuration, LockScreenFiles.isVideoName(configuration) else {
            self = .follow
            return
        }
        self = .video(configuration)
    }
}

enum LockScreenPlayback {
    /// shortcut: `shuffleIndex` walks back at most this many slots; past it a video may repeat once (odds below 1e-11
    /// with three videos); raise it if a repeat is ever seen.
    private static let shuffleLookBack = 64

    /// Never in the Settings preview, with the displays asleep, on a suspended surface, while the app is paused, under
    /// the power and Reduce Motion rules the app's settings turn on, or when the Mac runs hot. Otherwise video decodes
    /// on the lock screen and under the screen saver, and on the desktop only when the app plays there too and windows
    /// do not cover the surface's display (an unknown display is not covered); elsewhere the surface holds a still
    /// frame. As in Phosphene, loginwindow's lock counts before the agent's own `locked` update arrives, and `idle` is
    /// the screen-saver presentation.
    static func shouldDecode(_ surface: SurfacePresentation, _ screen: ScreenState, _ flags: PlaybackFlags) -> Bool {
        guard !surface.isPreview, !screen.displaysAsleep, surface.activity != .suspended, !flags.paused,
              !(screen.lowPowerMode && flags.pauseInLowPowerMode), !(screen.onBattery && flags.pauseOnBattery),
              !(screen.reduceMotion && flags.pauseWithReduceMotion), !screen.thermalHigh else { return false }
        let lockOrScreenSaver = screen.screenLocked || screen.screenSaverRunning
            || surface.mode == .locked || surface.mode == .idle
        let covered = surface.displayID.map { flags.coveredDisplays.contains($0) } ?? false
        return lockOrScreenSaver || (surface.mode == .desktop && flags.desktop && !covered)
    }

    /// The clone a catalog video plays: its battery clone on battery power, in Low Power Mode or while the Mac is warm,
    /// when the app made one; otherwise its main file.
    static func variantFile(of item: WallpaperCatalog.Item, _ screen: ScreenState) -> String {
        guard let battery = item.batteryFile, screen.onBattery || screen.lowPowerMode || screen.thermalElevated
        else { return item.file }
        return battery
    }

    /// Whether a surface's player, playing `current`, takes its resolved file at its next loop instead of being
    /// replaced: for the same video, decoding or held (a pending switch waits through a pause), while `current` is still
    /// that video's own file or its listed battery clone, and readable. Another video, or a file gone from the catalog
    /// or the disk, gets a new player.
    static func switchesAtLoop(sameVideo: Bool, playing current: String, video: String, catalog: WallpaperCatalog?,
                               currentReadable: Bool) -> Bool {
        guard sameVideo, currentReadable else { return false }
        return current == video || catalog?.items.contains { $0.file == video && $0.batteryFile == current } == true
    }

    /// Whether a Shuffle surface's player moves to the slot's next video at its loop instead of being replaced: only a
    /// player Shuffle already runs (`running`: decoding, and attached for Shuffle rather than another tile), while the
    /// video it shows (`shown`, its main file; nil once replaced under it) is still listed, and `current` is that
    /// video's file or battery clone and readable. A held player, a new pick, or a video gone from the catalog or the
    /// disk gets a new player at once.
    static func shuffleSwitchesAtLoop(running: Bool, showing shown: String?, playing current: String,
                                      catalog: WallpaperCatalog?, currentReadable: Bool) -> Bool {
        guard running, currentReadable,
              let item = catalog?.items.first(where: { $0.file == shown }) else { return false }
        return current == item.file || current == item.batteryFile
    }

    /// Which catalog item the Shuffle tile plays at `date`: wall-clock time cut into `interval`-long slots, each taking
    /// item splitmix64(slot) % count, or the next item when that is the previous slot's. The clock alone decides, so
    /// every display shows the same video and a restarted extension carries on with it. nil without items, or for an
    /// interval that is not positive.
    static func shuffleIndex(at date: Date, interval: TimeInterval, count: Int) -> Int? {
        guard count > 0, interval > 0,
              let slot = Int(exactly: (date.timeIntervalSince1970 / interval).rounded(.down)) else { return nil }
        // With two items the rule alternates; no earlier slot fixes the phase, so the slot's parity does.
        guard count > 2 else { return count == 1 ? 0 : slot & 1 }
        let pick = { (slot: Int) in Int(splitmix64(UInt64(bitPattern: Int64(slot))) % UInt64(count)) }
        // A slot's item depends on the previous slot's only when its pick is one of the two items that one can be: walk
        // back to a slot whose pick is neither, then apply the rule forward from it.
        var first = slot
        while first > slot - shuffleLookBack {
            let previous = pick(first - 1), own = pick(first)
            guard own == previous || own == (previous + 1) % count else { break }
            first -= 1
        }
        var index = pick(first)
        for later in stride(from: first + 1, through: slot, by: 1) {
            let own = pick(later)
            index = own == index ? (own + 1) % count : own
        }
        return index
    }

    /// The next slot boundary after `date`: when Shuffle moves to its next video. nil for an interval that is not
    /// positive, which has no slots.
    static func nextChange(after date: Date, interval: TimeInterval) -> Date? {
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: ((date.timeIntervalSince1970 / interval).rounded(.down) + 1) * interval)
    }

    /// SplitMix64's output step: a fixed hash of `seed`, the same on every Mac and every OS version.
    static func splitmix64(_ seed: UInt64) -> UInt64 {
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A new app video or catalog re-points the surfaces it affects; flags alone change nothing here. Same file with
    /// a new `updated`: the app copied it again, so players reading the old copy start over. The same goes for
    /// `refreshedCatalogFiles`, the files both catalogs list with a different `updated` (an added or removed file is
    /// not one of them).
    static func change(from oldState: LockScreenState?, oldURL: URL?, oldCatalog: WallpaperCatalog?,
                       to state: LockScreenState?, url: URL?, catalog: WallpaperCatalog?)
        -> (followChanged: Bool, catalogChanged: Bool, refreshFollowVideo: Bool, refreshedCatalogFiles: Set<String>) {
        let updatedChanged = state?.updated != oldState?.updated
        let followChanged = state?.file != oldState?.file || updatedChanged || url != oldURL
        let refresh = url != nil && url == oldURL && updatedChanged
        return (followChanged, catalog != oldCatalog, refresh, refreshedFiles(from: oldCatalog, to: catalog))
    }

    private static func refreshedFiles(from old: WallpaperCatalog?, to new: WallpaperCatalog?) -> Set<String> {
        let oldRevisions = Dictionary((old?.items ?? []).map { ($0.file, $0.updated) },
                                      uniquingKeysWith: { first, _ in first })
        let refreshed = (new?.items ?? []).filter { item in oldRevisions[item.file].map { $0 != item.updated } ?? false }
        return Set(refreshed.map(\.file))
    }
}
