import Foundation

// MARK: PlaybackPolicy

var good = PlaybackConditions()
good.hasVideo = true
precondition(PlaybackPolicy.shouldPlay(good))
precondition(PlaybackPolicy.autoPauseReason(good) == nil)

let blockers: [(AutoPauseReason, (inout PlaybackConditions) -> Void)] = [
    (.screensAsleep, { $0.screensAsleep = true }),
    (.screenLocked, { $0.screenLocked = true }),
    (.lowPowerMode, { $0.lowPowerMode = true }),
    (.desktopCovered, { $0.desktopVisible = false }),
    (.onBattery, { $0.onBattery = true; $0.rules.onBattery = true }),
]
for (reason, apply) in blockers {
    var c = good
    apply(&c)
    precondition(!PlaybackPolicy.shouldPlay(c))
    precondition(PlaybackPolicy.autoPauseReason(c) == reason)
}

// A switched-off rule lets playback continue.
let disabledRules: [(inout PlaybackConditions) -> Void] = [
    { $0.screenLocked = true; $0.rules.whenLocked = false },
    { $0.lowPowerMode = true; $0.rules.inLowPowerMode = false },
    { $0.desktopVisible = false; $0.rules.whenCovered = false },
    { $0.onBattery = true },  // battery rule is off by default
]
for apply in disabledRules {
    var c = good
    apply(&c)
    precondition(PlaybackPolicy.shouldPlay(c))
}

var paused = good
paused.userPaused = true
precondition(!PlaybackPolicy.shouldPlay(paused))
precondition(PlaybackPolicy.autoPauseReason(paused) == nil)
precondition(!PlaybackPolicy.shouldPlay(PlaybackConditions()))
precondition(PlaybackPolicy.autoPauseReason(PlaybackConditions()) == nil)

var asleepAndLocked = good
asleepAndLocked.screensAsleep = true
asleepAndLocked.screenLocked = true
asleepAndLocked.rules.whenLocked = false
precondition(PlaybackPolicy.autoPauseReason(asleepAndLocked) == .screensAsleep)

// MARK: LibraryNaming

precondition(LibraryNaming.parse(fileName: "zzz-green-4k.mp4") == ParsedVideoName(base: "zzz-green", variant: .fourK))
precondition(LibraryNaming.parse(fileName: "Sunset-2160P.MOV") == ParsedVideoName(base: "Sunset", variant: .fourK))
precondition(LibraryNaming.parse(fileName: "zzz-green-2k.mp4") == ParsedVideoName(base: "zzz-green", variant: .twoK))
precondition(LibraryNaming.parse(fileName: "rain_1440p.m4v") == ParsedVideoName(base: "rain_1440p", variant: .original))
precondition(LibraryNaming.parse(fileName: "rain-1080p.m4v") == ParsedVideoName(base: "rain", variant: .twoK))
precondition(LibraryNaming.parse(fileName: "ocean.mp4") == ParsedVideoName(base: "ocean", variant: .original))
precondition(LibraryNaming.parse(fileName: "-4k.mp4") == ParsedVideoName(base: "-4k", variant: .original))
precondition(LibraryNaming.parse(fileName: "notes.txt") == nil)
precondition(LibraryNaming.parse(fileName: "ocean-thumb.png") == nil)
precondition(LibraryNaming.thumbnailBase(fileName: "zzz-green-thumb.png") == "zzz-green")
precondition(LibraryNaming.thumbnailBase(fileName: "ocean-THUMB.jpg") == "ocean")
precondition(LibraryNaming.thumbnailBase(fileName: "ocean.png") == nil)
precondition(LibraryNaming.title(fromBase: "zzz-green_neon") == "zzz green neon")

let groups = LibraryNaming.group(fileNames: [
    "zzz-green-4k.mp4", "zzz-green-2k.mp4", "zzz-green-thumb.png", "ocean.mov", "wallpapers.json",
])
precondition(groups.map(\.base) == ["ocean", "zzz-green"])
precondition(groups[1].files == [.fourK: "zzz-green-4k.mp4", .twoK: "zzz-green-2k.mp4"])
precondition(groups[1].thumbnail == "zzz-green-thumb.png" && groups[0].thumbnail == nil)
precondition(LibraryNaming.ordered(["a", "b", "c", "item10", "item2"], by: ["c", "x", "c", "a"])
    == ["c", "a", "b", "item2", "item10"])
do {
    let bigOrder = (0..<20_000).map { "n\($0)" } + Array(repeating: "b", count: 20_000)
    let start = ContinuousClock.now
    let result = LibraryNaming.ordered(["a", "b", "c"], by: bigOrder)
    precondition(result == ["b", "a", "c"])
    precondition(ContinuousClock.now - start < .milliseconds(500))
}

// MARK: VariantChooser

let all: Set<VideoVariant> = [.original, .twoK, .fourK]
precondition(VariantChooser.choose(.auto, available: all, maxPixelWidth: 5120, onBattery: false) == .fourK)
precondition(VariantChooser.choose(.auto, available: all, maxPixelWidth: 3200, onBattery: false) == .fourK)
// 14" MacBook Pro Retina (1512 pt × 2) stays on 2K; so does any screen on battery.
precondition(VariantChooser.choose(.auto, available: all, maxPixelWidth: 3024, onBattery: false) == .twoK)
precondition(VariantChooser.choose(.auto, available: all, maxPixelWidth: 5120, onBattery: true) == .twoK)
precondition(VariantChooser.choose(.fourK, available: all, maxPixelWidth: 1440, onBattery: true) == .fourK)
precondition(VariantChooser.choose(.twoK, available: all, maxPixelWidth: 5120, onBattery: false) == .twoK)
precondition(VariantChooser.choose(.fourK, available: [.original, .twoK], maxPixelWidth: 0, onBattery: false) == .original)
precondition(VariantChooser.choose(.twoK, available: [.fourK], maxPixelWidth: 0, onBattery: false) == .fourK)
precondition(VariantChooser.choose(.auto, available: [], maxPixelWidth: 0, onBattery: false) == nil)

// MARK: In-library rule (depth ≤ 1 under a root, supported name)

let roots = ["/lib", "/app/Wallpapers/"]
precondition(LibraryNaming.isLibraryFile(path: "/lib/a.mp4", roots: roots))
precondition(LibraryNaming.isLibraryFile(path: "/lib/Nature/a-4k.mov", roots: roots))
precondition(LibraryNaming.isLibraryFile(path: "/app/Wallpapers/Space/b.m4v", roots: roots))
precondition(!LibraryNaming.isLibraryFile(path: "/lib/Nature/deep/a.mp4", roots: roots))
precondition(!LibraryNaming.isLibraryFile(path: "/lib/Nature/a.avi", roots: roots))
precondition(!LibraryNaming.isLibraryFile(path: "/library/a.mp4", roots: roots))
precondition(!LibraryNaming.isLibraryFile(path: "/lib/.hidden/a.mp4", roots: roots))

// MARK: Category order

func emptyCategory(_ name: String) -> LibraryCategory { LibraryCategory(name: name, items: []) }
let unsorted = ["", "beta", "Zeta", "alpha", "Nature"].map(emptyCategory)
precondition(LibraryScanner.sortCategories(unsorted, defaultCategory: "Zeta").map(\.name)
    == ["Zeta", "alpha", "beta", "Nature", ""])
precondition(LibraryScanner.sortCategories(unsorted, defaultCategory: nil).map(\.name)
    == ["alpha", "beta", "Nature", "Zeta", ""])

// MARK: LibraryScanner (empty fake files; the scanner never decodes video)

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("lw-selftest-\(UUID().uuidString)", isDirectory: true)
let lib = tmp.appendingPathComponent("lib", isDirectory: true)
let fixtures: [String: String] = [
    "lib/Nature/ocean-4k.mp4": "", "lib/Nature/ocean-2k.mp4": "", "lib/Nature/ocean-thumb.png": "",
    "lib/Nature/rain.mov": "", "lib/Nature/deep/nested.mp4": "",
    "lib/Nature/wallpapers.json": #"{"order": ["rain"], "items": {"ocean": {"title": "Blue Ocean", "default": true}}}"#,
    "lib/Broken/clip.mp4": "", "lib/Broken/wallpapers.json": "{not json",
    "lib/loose.mp4": "",
    "bundled/Nature/forest.mp4": "",
    "bundled/Space/stars.mp4": "", "bundled/Space/wallpapers.json": #"{"items": {"stars": {"default": true}}}"#,
    "outside/linked.mp4": "",
]
for (path, contents) in fixtures {
    let url = tmp.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    precondition(fm.createFile(atPath: url.path, contents: Data(contents.utf8)))
}
// A symlinked folder is followed once; links to the root itself or above it are skipped.
try! fm.createSymbolicLink(at: lib.appendingPathComponent("Linked"), withDestinationURL: tmp.appendingPathComponent("outside"))
try! fm.createSymbolicLink(at: lib.appendingPathComponent("Loop"), withDestinationURL: lib)
try! fm.createSymbolicLink(at: lib.appendingPathComponent("Up"), withDestinationURL: tmp)

let scan = LibraryScanner.scan(libraryRoot: lib, createIfMissing: false,
                               bundledRoot: tmp.appendingPathComponent("bundled"))
precondition(scan.rootError == nil)
precondition(scan.categories.map(\.name) == ["Nature", "Broken", "Linked", "Space", ""])
let nature = scan.categories[0].items
// Sidecar order first, then the rest; bundled items of the same folder name merge in after the library's.
precondition(nature.map(\.title) == ["rain", "Blue Ocean", "forest"])
precondition(Set(nature[1].variants.keys) == [.fourK, .twoK] && nature[1].thumbnail?.lastPathComponent == "ocean-thumb.png")
precondition(nature[1].isDefault && scan.defaultItem?.id == nature[1].id)
precondition(scan.warnings == [.badSidecar(folder: "Broken")])
precondition(scan.categories[1].items.map(\.title) == ["clip"])
precondition(scan.categories[2].items.map(\.title) == ["linked"])
precondition(scan.categories[3].items.map(\.title) == ["stars"])
precondition(scan.categories[4].items.map(\.title) == ["loose"] && scan.categories[4].items[0].category.isEmpty)

let realRoots = [lib.resolvingSymlinksInPath().path]
precondition(LibraryNaming.isLibraryFile(
    path: lib.appendingPathComponent("Nature/rain.mov").resolvingSymlinksInPath().path, roots: realRoots))
precondition(!LibraryNaming.isLibraryFile(
    path: lib.appendingPathComponent("Nature/deep/nested.mp4").resolvingSymlinksInPath().path, roots: realRoots))

// A file opened through a symlinked folder: resolving alone leaves the root, so the unresolved path counts too.
let viaLink = lib.appendingPathComponent("Linked/linked.mp4")
precondition(!LibraryNaming.isLibraryFile(path: viaLink.resolvingSymlinksInPath().path, roots: realRoots))
precondition(LibraryScanner.isLibraryFile(viaLink, roots: [lib]))
precondition(LibraryScanner.isLibraryFile(lib.resolvingSymlinksInPath().appendingPathComponent("Nature/rain.mov"),
                                          roots: [lib]))
precondition(!LibraryScanner.isLibraryFile(tmp.appendingPathComponent("outside/linked.mp4"), roots: [lib]))
precondition(!LibraryScanner.isLibraryFile(lib.appendingPathComponent("Nature/deep/nested.mp4"), roots: [lib]))

// Launch fallback: the default is skipped when the file that just failed is one of its variants.
precondition(nature[1].hasFile(atPath: nature[1].variants[.fourK]?.path))
precondition(!nature[1].hasFile(atPath: nature[0].variants[.original]?.path))
precondition(!nature[1].hasFile(atPath: nil))

let missing = LibraryScanner.scan(libraryRoot: tmp.appendingPathComponent("missing"), createIfMissing: false,
                                  bundledRoot: nil)
precondition(missing.rootError != nil && missing.categories.isEmpty && missing.defaultItem == nil)
let created = LibraryScanner.scan(libraryRoot: tmp.appendingPathComponent("new"), createIfMissing: true,
                                  bundledRoot: tmp.appendingPathComponent("absent"))
precondition(created.rootError == nil && created.categories.isEmpty && created.warnings.isEmpty)

// Hostile sidecars: an oversized file is treated as malformed; long titles are clamped.
let hugeJSON = #"{"items": {"big": {"title": "x"}}, "pad": ""# + String(repeating: "a", count: 70_000) + #""}"#
let longTitle = String(repeating: "t", count: 200)
let hostile: [String: String] = [
    "hostile/Huge/big.mp4": "", "hostile/Huge/wallpapers.json": hugeJSON,
    "hostile/Long/clip.mp4": "", "hostile/Long/wallpapers.json": #"{"items": {"clip": {"title": "  \#(longTitle)  "}}}"#,
]
for (path, contents) in hostile {
    let url = tmp.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    precondition(fm.createFile(atPath: url.path, contents: Data(contents.utf8)))
}
let hostileScan = LibraryScanner.scan(libraryRoot: tmp.appendingPathComponent("hostile"), createIfMissing: false,
                                      bundledRoot: nil)
precondition(hostileScan.warnings == [.badSidecar(folder: "Huge")])
precondition(hostileScan.categories.first { $0.name == "Huge" }?.items.map(\.title) == ["big"])
precondition(hostileScan.categories.first { $0.name == "Long" }?.items.map(\.title) == [String(repeating: "t", count: 80)])

try! fm.removeItem(at: tmp)

// MARK: LockScreenFiles (names, state.json, cleanup)

do {
    guard let sunset = LockScreenFiles.videoName(forSourcePath: "/Users/a/Movies/Sunset-4K.MOV") else {
        preconditionFailure("a .MOV source must get a name")
    }
    precondition(sunset == LockScreenFiles.videoName(forSourcePath: "/Users/a/Movies/Sunset-4K.MOV"))
    precondition(sunset.hasPrefix("video-") && sunset.hasSuffix(".mov") && sunset.count == 26)
    precondition(sunset != LockScreenFiles.videoName(forSourcePath: "/Users/a/Movies/Sunset-2K.MOV"))
    // Pinned to SHA-256("abc.mp4"), so a name never changes between builds.
    precondition(LockScreenFiles.videoName(forSourcePath: "abc.mp4") == "video-e7b7d9f2bb90dad0.mp4")
    // Only mp4, mov and m4v get a name: a playlist, an odd extension or none at all is never mirrored.
    for path in ["abc", "/x/clip.mp4%", "/x/live.m3u8", "/x/clip.webm"] {
        precondition(LockScreenFiles.videoName(forSourcePath: path) == nil, path)
    }
    precondition(LockScreenFiles.isVideoName(sunset) && LockScreenFiles.isVideoName("video-e7b7d9f2bb90dad0.m4v"))
    let notOurs = ["", "..", "../video-0123456789abcdef.mp4", "video-0123456789abcdef/../x", "/video-0123456789abcdef",
                   "video-0123456789ABCDEF.mp4", "video-0123456789abcde.mp4", "video-0123456789abcdef.",
                   "video-0123456789abcdef.mp4.mov", "video-０123456789abcdef", "current.mp4", "state.json",
                   ".partial-video-0123456789abcdef.mp4", "video-0123456789abcdef", "video-0123456789abcdef.m3u8"]
    for name in notOurs { precondition(!LockScreenFiles.isVideoName(name), name) }
    let margin = LockScreenFiles.copyMarginBytes
    precondition(LockScreenFiles.isEnoughSpace(sourceBytes: 100, availableBytes: 100 + margin))
    precondition(!LockScreenFiles.isEnoughSpace(sourceBytes: 100, availableBytes: 99 + margin))

    let folderNames = [sunset, "video-aaaaaaaaaaaaaaaa.mp4", ".partial-video-bbbbbbbbbbbbbbbb.mov", ".partial-notes.txt",
                       "current.mp4", "state.json", "thumbnail.png", ".DS_Store", "video-notes.txt"]
    precondition(LockScreenFiles.staleFiles(in: folderNames, keeping: sunset)
        == ["video-aaaaaaaaaaaaaaaa.mp4", ".partial-video-bbbbbbbbbbbbbbbb.mov"])
    precondition(LockScreenFiles.staleFiles(in: folderNames, keeping: nil)
        == [sunset, "video-aaaaaaaaaaaaaaaa.mp4", ".partial-video-bbbbbbbbbbbbbbbb.mov"])

    let state = LockScreenState(file: sunset, updated: 1_700_000_000)
    precondition(LockScreenFiles.decode(try! LockScreenFiles.encode(state)) == state)
    let hostileStates = [
        #"{"file": "../../.ssh/id_rsa", "updated": 1}"#,
        #"{"file": "current.mp4", "updated": 1}"#,
        #"{"file": "video-0123456789abcdef.m3u8", "updated": 1}"#,
        #"{"file": "\#(sunset)"}"#,
        "not json",
        #"{"file": "\#(sunset)", "updated": 1}"# + String(repeating: " ", count: 5_000),
    ]
    for json in hostileStates { precondition(LockScreenFiles.decode(Data(json.utf8)) == nil, json) }
}

// MARK: LockScreenFiles (mirror and clear on disk)

do {
    let root = fm.temporaryDirectory.appendingPathComponent("lw-lock-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("LockScreen", isDirectory: true)
    let sourceA = root.appendingPathComponent("src/a.mp4"), sourceB = root.appendingPathComponent("src/B.MOV")
    let userFiles = ["LockScreen/current.mp4": "spike", "LockScreen/notes.txt": "mine", "outside.mp4": "secret"]
    for (path, contents) in userFiles.merging(["src/a.mp4": "one", "src/B.MOV": "two"], uniquingKeysWith: { $1 }) {
        let url = root.appendingPathComponent(path)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        precondition(fm.createFile(atPath: url.path, contents: Data(contents.utf8)))
    }
    func contents(_ name: String) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    try! LockScreenFiles.mirror(sourceA, into: folder, now: Date(timeIntervalSince1970: 1_000))
    guard let nameA = LockScreenFiles.videoName(forSourcePath: sourceA.path),
          let nameB = LockScreenFiles.videoName(forSourcePath: sourceB.path) else {
        preconditionFailure("mp4 and MOV sources must get names")
    }
    precondition(LockScreenFiles.readState(in: folder) == LockScreenState(file: nameA, updated: 1_000))
    precondition(contents(nameA) == "one")
    precondition(LockScreenFiles.videoURL(for: LockScreenState(file: nameA, updated: 1), in: folder)?
        .lastPathComponent == nameA)
    // The same source again: no new copy and no rewrite, so the extension does not restart the video.
    try! LockScreenFiles.mirror(sourceA, into: folder, now: Date(timeIntervalSince1970: 2_000))
    precondition(LockScreenFiles.readState(in: folder)?.updated == 1_000)
    // A state.json in the 0.2.0-dev format (with a title) is rewritten without it, keeping `updated`.
    try! Data(#"{"file":"\#(nameA)","title":"A","updated":1000}"#.utf8)
        .write(to: folder.appendingPathComponent(LockScreenFiles.stateName))
    try! LockScreenFiles.mirror(sourceA, into: folder, now: Date(timeIntervalSince1970: 2_200))
    precondition(contents(LockScreenFiles.stateName) == #"{"file":"\#(nameA)","updated":1000}"#)
    // The same path with new content (same size, new modification date): copied again, state rewritten.
    precondition(fm.createFile(atPath: sourceA.path, contents: Data("uno".utf8)))
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234_567)], ofItemAtPath: sourceA.path)
    try! LockScreenFiles.mirror(sourceA, into: folder, now: Date(timeIntervalSince1970: 2_500))
    precondition(contents(nameA) == "uno" && LockScreenFiles.readState(in: folder)?.updated == 2_500)

    // Two paths in the same temp dir are on one volume; a path that does not exist has no identifier.
    precondition(LockScreenFiles.isSameVolume(sourceA, folder))
    precondition(!LockScreenFiles.isSameVolume(sourceA, root.appendingPathComponent("missing")))

    // A partial copy an interrupted run left behind is replaced, and no partial file stays.
    precondition(fm.createFile(atPath: folder.appendingPathComponent(".partial-" + nameB).path, contents: Data("junk".utf8)))
    try! LockScreenFiles.mirror(sourceB, into: folder, now: Date(timeIntervalSince1970: 3_000))
    precondition(LockScreenFiles.readState(in: folder) == LockScreenState(file: nameB, updated: 3_000))
    precondition(nameB.hasSuffix(".mov") && contents(nameB) == "two" && contents(nameA) == nil)
    precondition(contents("current.mp4") == "spike" && contents("notes.txt") == "mine")
    precondition(!(try! fm.contentsOfDirectory(atPath: folder.path)).contains { $0.hasPrefix(".partial-") })

    // A symlinked source is copied as the file it points to; a type the Lock Screen does not play is refused.
    let linkedSource = root.appendingPathComponent("src/linked.mp4"), target = root.appendingPathComponent("src/c.mp4")
    precondition(fm.createFile(atPath: target.path, contents: Data("three".utf8)))
    try! fm.createSymbolicLink(at: linkedSource, withDestinationURL: target)
    try! LockScreenFiles.mirror(linkedSource, into: folder, now: Date(timeIntervalSince1970: 3_500))
    guard let linkedName = LockScreenFiles.readState(in: folder)?.file else { preconditionFailure("no state") }
    precondition(linkedName != nameB && contents(linkedName) == "three"
        && (try! fm.attributesOfItem(atPath: folder.appendingPathComponent(linkedName).path))[.type] as? FileAttributeType == .typeRegular)
    do {
        try LockScreenFiles.mirror(root.appendingPathComponent("src/live.m3u8"), into: folder)
        preconditionFailure("an .m3u8 source must be refused")
    } catch {
        precondition(error as? LockScreenFilesError == .unsupportedType("m3u8"), "\(error)")
    }
    precondition(LockScreenFiles.readState(in: folder)?.file == linkedName)

    // The extension's checks: a missing file, a symlink out of the folder, a folder posing as a video.
    precondition(LockScreenFiles.videoURL(for: LockScreenState(file: nameA, updated: 1), in: folder) == nil)
    let link = "video-cccccccccccccccc.mp4", directory = "video-dddddddddddddddd.mp4"
    try! fm.createSymbolicLink(at: folder.appendingPathComponent(link), withDestinationURL: root.appendingPathComponent("outside.mp4"))
    precondition(LockScreenFiles.videoURL(for: LockScreenState(file: link, updated: 1), in: folder) == nil)
    try! fm.createDirectory(at: folder.appendingPathComponent(directory), withIntermediateDirectories: false)
    precondition(LockScreenFiles.videoURL(for: LockScreenState(file: directory, updated: 1), in: folder) == nil)

    // state.json must be a regular file of at most 4 KB: oversized, a symlink to a valid state, and a FIFO
    // (which must not block the reader) all read as no state.
    let stateURL = folder.appendingPathComponent(LockScreenFiles.stateName)
    let valid = try! LockScreenFiles.encode(LockScreenState(file: nameB, updated: 1))
    try! (valid + Data(repeating: 0x20, count: 5_000)).write(to: stateURL)
    precondition(LockScreenFiles.readState(in: folder) == nil)
    let elsewhere = root.appendingPathComponent("state-elsewhere.json")
    try! valid.write(to: elsewhere)
    try! fm.removeItem(at: stateURL)
    try! fm.createSymbolicLink(at: stateURL, withDestinationURL: elsewhere)
    precondition(LockScreenFiles.readState(in: folder) == nil)
    try! fm.removeItem(at: stateURL)
    precondition(mkfifo(stateURL.path, 0o600) == 0)
    precondition(LockScreenFiles.readState(in: folder) == nil)

    // Clear removes state.json and the app's videos (the link and folder too: their names are ours),
    // never the user's files.
    try! LockScreenFiles.clear(folder)
    let left = Set(try! fm.contentsOfDirectory(atPath: folder.path))
    precondition(left == ["current.mp4", "notes.txt"], "\(left)")
    precondition(fm.fileExists(atPath: root.appendingPathComponent("outside.mp4").path))
    try! LockScreenFiles.clear(root.appendingPathComponent("absent"))
    try! fm.removeItem(at: root)
}

// MARK: LockScreenPlayback (the extension decodes only when locked or under the screen saver)

do {
    let desktop = SurfacePresentation(isPreview: false)
    let preview = SurfacePresentation(isPreview: true)
    let locked = ScreenState(screenLocked: true)
    precondition(!LockScreenPlayback.shouldDecode(desktop, ScreenState()))
    precondition(LockScreenPlayback.shouldDecode(desktop, locked))
    precondition(LockScreenPlayback.shouldDecode(desktop, ScreenState(screenSaverRunning: true)))
    precondition(LockScreenPlayback.shouldDecode(SurfacePresentation(isPreview: false, mode: .locked), ScreenState()))
    precondition(LockScreenPlayback.shouldDecode(SurfacePresentation(isPreview: false, mode: .idle), ScreenState()))
    precondition(!LockScreenPlayback.shouldDecode(preview, locked))
    precondition(!LockScreenPlayback.shouldDecode(desktop, ScreenState(screenLocked: true, displaysAsleep: true)))
    precondition(!LockScreenPlayback.shouldDecode(SurfacePresentation(isPreview: false, activity: .suspended), locked))
    precondition(PresentationMode(caseName: "default") == .desktop && PresentationMode(caseName: "locked") == .locked)
    precondition(PresentationMode(caseName: "idle") == .idle && PresentationMode(caseName: "new") == .other)
    precondition(ActivityState(caseName: "suspendedForDisplaySleep") == .suspended)
    precondition(ActivityState(caseName: "active") == .active && ActivityState(caseName: "x") == .other)
}

print("selftest ok")
