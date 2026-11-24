import Foundation

// 0.4.0's checks: state.json's new keys, covered displays, the clone and Shuffle rules, and desktop coverage. Called
// from main.swift.

// MARK: PlaybackFlags (coveredDisplays and shuffleInterval in state.json, batteryFile in catalog.json)

func checkNewStateKeys(file sunset: String) {
    // 0.3.x wrote no coveredDisplays and no shuffleInterval: no display is covered, and Shuffle changes every 15 min.
    let uncoveredState = #"{"file":"\#(sunset)","updated":5,"desktop":true,"pauseWithReduceMotion":false}"#
    precondition(LockScreenFiles.decode(Data(uncoveredState.utf8))?.flags.coveredDisplays == [])
    precondition(LockScreenFiles.decode(Data(uncoveredState.utf8))?.flags.shuffleInterval == 900)
    // Only the four offered intervals decode as they are; any other number reads as 15 min, and so does one built.
    func decodedInterval(_ seconds: Int) -> Int? {
        LockScreenFiles.decode(Data(#"{"file":"\#(sunset)","updated":5,"shuffleInterval":\#(seconds)}"#.utf8))?
            .flags.shuffleInterval
    }
    for seconds in PlaybackFlags.shuffleIntervals { precondition(decodedInterval(seconds) == seconds, "\(seconds)") }
    for seconds in [0, -900, 1, 299, 301, 899, 901, 3_601, 86_401, 604_800] {
        precondition(decodedInterval(seconds) == 900, "\(seconds)")
    }
    precondition(PlaybackFlags(shuffleInterval: 42).shuffleInterval == 900)
    precondition(PlaybackFlags(shuffleInterval: 300).shuffleInterval == 300)
    let shuffled = LockScreenState(file: sunset, updated: 8, flags: PlaybackFlags(desktop: true, shuffleInterval: 3_600))
    precondition(LockScreenFiles.decode(try! LockScreenFiles.encode(shuffled)) == shuffled)
    let covered = LockScreenState(file: sunset, updated: 7, flags: PlaybackFlags(desktop: true, coveredDisplays: [1, 5]))
    precondition(LockScreenFiles.decode(try! LockScreenFiles.encode(covered)) == covered)

    // A new key of the wrong JSON type reads as its default; the state and its other keys still decode.
    func decodedFlags(_ pair: String) -> PlaybackFlags? {
        LockScreenFiles.decode(Data(#"{"file":"\#(sunset)","paused":true,"updated":5,\#(pair)}"#.utf8))?.flags
    }
    precondition(decodedFlags(#""shuffleInterval":900.5"#)?.shuffleInterval == 900)
    precondition(decodedFlags(#""shuffleInterval":"900""#)?.shuffleInterval == 900)
    let negative = decodedFlags(#""coveredDisplays":[-1]"#)
    precondition(negative?.coveredDisplays == [] && negative?.paused == true, "\(String(describing: negative))")
    // So does a battery clone that is no string: the item stays, without one.
    let a = "video-aaaaaaaaaaaaaaaa.mp4"
    let numericBattery = #"{"items":[{"batteryFile":5,"file":"\#(a)","title":"A","updated":3}]}"#
    precondition(LockScreenFiles.decodeCatalog(Data(numericBattery.utf8))?.items == [.init(file: a, title: "A", updated: 3)])
}

// MARK: LockScreenPlayback.shouldDecode (covered displays)

func checkCoveredDisplaysDecode() {
    let decodes = LockScreenPlayback.shouldDecode
    let desktop = SurfacePresentation(isPreview: false)
    let locked = ScreenState(screenLocked: true)
    // Windows covering a surface's display hold its desktop still; the lock screen and unknown displays play on.
    let coveredTwo = PlaybackFlags(desktop: true, coveredDisplays: [2])
    precondition(!decodes(SurfacePresentation(isPreview: false, displayID: 2), ScreenState(), coveredTwo))
    precondition(decodes(SurfacePresentation(isPreview: false, displayID: 1), ScreenState(), coveredTwo))
    precondition(decodes(SurfacePresentation(isPreview: false, mode: .locked, displayID: 2), ScreenState(), coveredTwo))
    precondition(decodes(SurfacePresentation(isPreview: false, displayID: 2), locked, coveredTwo))
    precondition(decodes(desktop, ScreenState(), coveredTwo))
}

// MARK: LockScreenFiles.updateFlags (covered displays released at quit)

/// What `LockScreenSync.releaseCoveredDisplays` writes: the list emptied, every other value kept, and nothing at all
/// when no display is listed.
func checkCoveredDisplaysReleased() {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("lw-release-\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let stateURL = folder.appendingPathComponent(LockScreenFiles.stateName)
    let file = "video-aaaaaaaaaaaaaaaa.mp4"
    func inode() -> Int? { (try? fm.attributesOfItem(atPath: stateURL.path))?[.systemFileNumber] as? Int }
    let flags = PlaybackFlags(desktop: true, paused: true, pauseOnBattery: true, coveredDisplays: [1, 5],
                              shuffleInterval: 3_600)
    try! LockScreenFiles.encode(LockScreenState(file: file, updated: 42, flags: flags)).write(to: stateURL)
    try! LockScreenFiles.updateFlags(in: folder) { $0.uncovered }
    let released = LockScreenFiles.readState(in: folder)
    let expected = PlaybackFlags(desktop: true, paused: true, pauseOnBattery: true, shuffleInterval: 3_600)
    precondition(released == LockScreenState(file: file, updated: 42, flags: expected), "\(String(describing: released))")
    // None listed: no write (an atomic write would give state.json a new inode).
    let before = inode()
    try! LockScreenFiles.updateFlags(in: folder) { $0.uncovered }
    precondition(before != nil && inode() == before)
    // No state.json: none is made.
    try! fm.removeItem(at: stateURL)
    try! LockScreenFiles.updateFlags(in: folder) { $0.uncovered }
    precondition(!fm.fileExists(atPath: stateURL.path))
    try! fm.removeItem(at: folder)
}

// MARK: LockScreenPlayback.variantFile (which clone a catalog video plays)

func checkVariantFile() {
    let variant = LockScreenPlayback.variantFile
    let item = WallpaperCatalog.Item(file: "video-aaaaaaaaaaaaaaaa.mp4", title: "A",
                                     batteryFile: "video-bbbbbbbbbbbbbbbb.mp4")
    // On AC, cool and out of Low Power Mode: the main file, whatever else the screen does.
    precondition(variant(item, ScreenState()) == item.file)
    precondition(variant(item, ScreenState(screenLocked: true, reduceMotion: true)) == item.file)
    // Battery power, Low Power Mode or a warm Mac: the battery clone.
    for screen in [ScreenState(onBattery: true), ScreenState(lowPowerMode: true), ScreenState(thermalElevated: true),
                   ScreenState(lowPowerMode: true, onBattery: true, thermalHigh: true, thermalElevated: true)] {
        precondition(variant(item, screen) == item.batteryFile, "\(screen)")
    }
    // Without a battery clone, the main file everywhere.
    let single = WallpaperCatalog.Item(file: item.file, title: "A")
    for screen in [ScreenState(), ScreenState(onBattery: true), ScreenState(lowPowerMode: true),
                   ScreenState(thermalElevated: true)] {
        precondition(variant(single, screen) == item.file, "\(screen)")
    }
}

// MARK: LockScreenPlayback.switchesAtLoop (a resolved clone: switch at the loop, or a new player)

func checkSwitchesAtLoop() {
    let main = "video-aaaaaaaaaaaaaaaa.mp4", battery = "video-bbbbbbbbbbbbbbbb.mp4", other = "video-cccccccccccccccc.mp4"
    let catalog = WallpaperCatalog(items: [.init(file: main, title: "A", batteryFile: battery),
                                           .init(file: other, title: "C")])
    func switches(_ sameVideo: Bool, _ current: String, _ catalog: WallpaperCatalog?, readable: Bool = true) -> Bool {
        LockScreenPlayback.switchesAtLoop(sameVideo: sameVideo, playing: current, video: main, catalog: catalog,
                                          currentReadable: readable)
    }
    // The same video, decoding or held alike (the rule never asks): on its main file or its listed battery clone, the
    // player takes the other clone at its next loop. The follow tile's file is the video itself, listed or not.
    precondition(switches(true, main, catalog) && switches(true, battery, catalog) && switches(true, main, nil))
    // The file it is on became unreadable: a new player.
    precondition(!switches(true, battery, catalog, readable: false) && !switches(true, main, catalog, readable: false))
    // The battery clone it is on is no longer listed (or is another video's file): a new player.
    precondition(!switches(true, battery, WallpaperCatalog(items: [.init(file: main, title: "A")])))
    precondition(!switches(true, battery, nil) && !switches(true, other, catalog))
    // Another video: a new player.
    precondition(!switches(false, main, catalog) && !switches(false, battery, catalog))
}

// MARK: LockScreenPlayback.shuffleSwitchesAtLoop (Shuffle's next video: switch at the loop, or a new player)

func checkShuffleSwitchesAtLoop() {
    let main = "video-aaaaaaaaaaaaaaaa.mp4", battery = "video-bbbbbbbbbbbbbbbb.mp4", other = "video-cccccccccccccccc.mp4"
    let catalog = WallpaperCatalog(items: [.init(file: main, title: "A", batteryFile: battery),
                                           .init(file: other, title: "C")])
    func switches(running: Bool = true, _ shown: String?, _ current: String, _ catalog: WallpaperCatalog?,
                  readable: Bool = true) -> Bool {
        LockScreenPlayback.shuffleSwitchesAtLoop(running: running, showing: shown, playing: current, catalog: catalog,
                                                 currentReadable: readable)
    }
    // A running Shuffle player on the listed video it shows, main file or battery clone: the next video at its loop.
    precondition(switches(main, main, catalog) && switches(main, battery, catalog) && switches(other, other, catalog))
    // Held, or not attached for Shuffle (a new pick): a new player.
    precondition(!switches(running: false, main, main, catalog) && !switches(running: false, main, battery, catalog))
    // The video it shows left the catalog, or there is none: a new player at once.
    precondition(!switches(main, main, WallpaperCatalog(items: [.init(file: other, title: "C")])))
    precondition(!switches(main, main, nil) && !switches(main, main, WallpaperCatalog(items: [])))
    // Its file was replaced under it, is unreadable, or is not that video's: a new player.
    precondition(!switches(nil, main, catalog) && !switches(main, main, catalog, readable: false))
    precondition(!switches(main, other, catalog) && !switches(other, battery, catalog))
}

// MARK: LockScreenPlayback.shuffleIndex (which catalog video Shuffle plays when)

func checkShuffleIndex() {
    let index = LockScreenPlayback.shuffleIndex
    let interval: TimeInterval = 900
    let start = Date(timeIntervalSince1970: 1_800_000_000) // a slot boundary: 2_000_000 × 900
    // Pinned to SplitMix64's first output from 0, so a schedule never changes between builds.
    precondition(LockScreenPlayback.splitmix64(0) == 0xE220_A839_7B1D_CDAF)
    precondition(index(start, interval, 0) == nil && index(start, interval, 1) == 0)
    precondition(index(start + 12_345 * interval, interval, 1) == 0)
    // Slot after slot (three weeks of 15 min for 2 and 3 videos, a day for 7 and 200): always in range, never the
    // previous slot's video, the same all through a slot and on every call, and every video comes up.
    for (count, slots) in [(2, 2_016), (3, 2_016), (7, 96), (200, 96)] {
        var previous: Int?
        var seen = Set<Int>()
        for slot in 0..<slots {
            let begin = start + Double(slot) * interval
            guard let current = index(begin, interval, count) else { preconditionFailure("count \(count)") }
            precondition((0..<count).contains(current), "count \(count) slot \(slot)")
            precondition(current != previous, "count \(count) repeats at slot \(slot)")
            precondition(index(begin + 0.5, interval, count) == current && index(begin, interval, count) == current)
            precondition(index(begin + interval - 0.001, interval, count) == current, "count \(count) slot \(slot)")
            previous = current
            seen.insert(current)
        }
        precondition(count > slots ? seen.count > slots / 2 : seen.count == count, "count \(count) shows \(seen.count)")
    }
    // The interval sets the slots: a day keeps one video all day.
    let day: TimeInterval = 86_400
    let dayStart = Date(timeIntervalSince1970: 1_800_057_600) // 20_834 × 86_400
    precondition(index(dayStart, day, 5) == index(dayStart + day - 1, day, 5)
        && index(dayStart, day, 5) != index(dayStart + day, day, 5))

    // nextChange: the next boundary, exactly, also from a boundary itself.
    guard let next = LockScreenPlayback.nextChange(after: start + 123.5, interval: interval) else {
        preconditionFailure("a positive interval has a next change")
    }
    precondition(next == start + interval)
    precondition(LockScreenPlayback.nextChange(after: start, interval: interval) == start + interval)
    precondition(LockScreenPlayback.nextChange(after: next - 0.001, interval: interval) == next)
    precondition(LockScreenPlayback.nextChange(after: dayStart + 1, interval: day) == dayStart + day)
    precondition(LockScreenPlayback.nextChange(after: start, interval: 300)?.timeIntervalSince1970 == 1_800_000_300)
    // The video changes there and not a moment before.
    precondition(index(next - 0.001, interval, 7) != index(next, interval, 7))
    // An interval that is not positive (the app never writes one) has no slots: no video and no next change.
    for bad in [0, -interval, .nan] {
        precondition(index(start, bad, 3) == nil && LockScreenPlayback.nextChange(after: start, interval: bad) == nil)
    }
}

// MARK: DesktopCoverage (which displays windows hide completely)

func checkDesktopCoverage() {
    let main = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    let side = CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080)
    func window(_ bounds: CGRect, layer: Int = 0, alpha: Double = 1) -> DesktopCoverage.Window {
        DesktopCoverage.Window(bounds: bounds, layer: layer, alpha: alpha)
    }
    func covered(_ windows: [DesktopCoverage.Window], topInsets: [UInt32: CGFloat] = [:]) -> [UInt32] {
        DesktopCoverage.coveredDisplays(windows: windows, displays: [1: main, 2: side], topInsets: topInsets)
    }

    // A full-screen window covers its display; a zoomed one below the menu bar leaves the strip.
    precondition(covered([window(main)]) == [1] && covered([]) == [])
    precondition(covered([window(CGRect(x: 0, y: 33, width: 1_512, height: 949))]) == [])

    // Two halves cover it together, not apart.
    let left = CGRect(x: 0, y: 0, width: 756, height: 982), right = CGRect(x: 756, y: 0, width: 756, height: 982)
    precondition(covered([window(left)]) == [] && covered([window(right)]) == [])
    precondition(covered([window(left), window(right)]) == [1])

    // Other layers (menu bar, Dock, panels) and see-through windows never cover.
    precondition(covered([window(main, layer: 25)]) == [] && covered([window(main, layer: -1)]) == [])
    precondition(covered([window(main, alpha: 0.5)]) == [] && covered([window(main, alpha: 0.99)]) == [1])
    precondition(covered([window(.zero), window(.null)]) == [])

    // Two displays: each covered on its own; a window spilling onto the second covers only the first.
    precondition(covered([window(side)]) == [2] && covered([window(side), window(main)]) == [1, 2])
    precondition(covered([window(CGRect(x: -10, y: -10, width: 2_000, height: 1_000))]) == [1])

    // A camera housing: a full-screen app starts below it and its Space hides the menu bar, so the black strip above
    // needs no window; while a menu bar (main menu or status layer) shows over the strip, it does.
    let notch: [UInt32: CGFloat] = [1: 32]
    let belowNotch = window(CGRect(x: 0, y: 32, width: 1_512, height: 950))
    let menuBar = window(CGRect(x: 0, y: 0, width: 1_512, height: 32), layer: 24)
    let statusItem = window(CGRect(x: 1_400, y: 0, width: 40, height: 32), layer: 25)
    precondition(covered([belowNotch], topInsets: notch) == [1])
    precondition(covered([belowNotch, menuBar], topInsets: notch) == [])
    precondition(covered([belowNotch, statusItem], topInsets: notch) == [])
    // Without a housing nothing changes; a menu bar on the other display does not show over this strip.
    precondition(covered([belowNotch]) == [] && covered([window(main), menuBar]) == [1])
    let sideMenuBar = window(CGRect(x: 1_512, y: 0, width: 1_920, height: 24), layer: 24)
    precondition(covered([belowNotch, sideMenuBar], topInsets: notch) == [1])
    // A window zoomed below the menu bar on the housing's display (Dock hidden), menu bar and status items present;
    // a full-screen window under the menu bar still covers.
    precondition(covered([belowNotch, menuBar, statusItem], topInsets: notch) == [])
    precondition(covered([window(main), menuBar], topInsets: notch) == [1])
}
