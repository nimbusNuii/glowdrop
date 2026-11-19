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

print("selftest ok")
