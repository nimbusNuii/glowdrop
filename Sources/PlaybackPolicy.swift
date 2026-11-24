/// Which auto-pause rules the user turned on in Settings.
struct PauseRules: Equatable {
    var whenCovered = true, whenLocked = true, inLowPowerMode = true, onBattery = false, withReduceMotion = true
}

struct PlaybackConditions: Equatable {
    var hasVideo = false, userPaused = false, screensAsleep = false
    var screenLocked = false, lowPowerMode = false, desktopVisible = true, onBattery = false, reduceMotion = false
    var rules = PauseRules()
}

/// Raw values are localization keys.
enum AutoPauseReason: String, Equatable {
    case screensAsleep = "pause.reason.screensAsleep"
    case screenLocked = "pause.reason.screenLocked"
    case lowPowerMode = "pause.reason.lowPowerMode"
    case onBattery = "pause.reason.onBattery"
    case reduceMotion = "pause.reason.reduceMotion"
    case desktopCovered = "pause.reason.desktopCovered"
}

enum PlaybackPolicy {
    static func shouldPlay(_ c: PlaybackConditions) -> Bool {
        c.hasVideo && !c.userPaused && autoPauseReason(c) == nil
    }

    /// Reason playback is auto-paused; nil when playing or when only userPaused / no video applies.
    static func autoPauseReason(_ c: PlaybackConditions) -> AutoPauseReason? {
        if c.screensAsleep { return .screensAsleep }
        if c.screenLocked && c.rules.whenLocked { return .screenLocked }
        if c.lowPowerMode && c.rules.inLowPowerMode { return .lowPowerMode }
        if c.onBattery && c.rules.onBattery { return .onBattery }
        if c.reduceMotion && c.rules.withReduceMotion { return .reduceMotion }
        if !c.desktopVisible && c.rules.whenCovered { return .desktopCovered }
        return nil
    }
}
