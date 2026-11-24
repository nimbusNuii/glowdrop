// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.

import CoreGraphics
import Foundation
import ImageIO

private let groupID = "glowdrop"
private let groupName = "Glowdrop"
private let followDescription = "Plays the wallpaper chosen in the Glowdrop app"
private let videoDescription = "Glowdrop video wallpaper"
private let shuffleName = "Shuffle"
private let shuffleDescription = "A different Glowdrop video at the interval set in the Glowdrop app"
/// Shuffle's tile image shows this many catalog videos, 2×2.
private let shuffleCollageItems = 4
private let thumbnailSize = CGSize(width: 640, height: 360)
private let catalogThumbnailSize = CGSize(width: 480, height: 270)
private let thumbnailTimeout: Duration = .seconds(5)
private let maxConcurrentThumbnails = 4
/// Builds per request when the catalog keeps changing underneath; the last one is used as it is.
private let maxSettingsBuilds = 3
/// The right-click menu on the group and every tile, as in Phosphene: Settings sends the item's id to
/// `invokeContextMenuAction`, which opens the matching glowdrop:// link in the app.
private let tileMenu = ContextMenu(items: [
    ContextMenuItem(id: ContextMenuItemID(id: GlowdropLink.addVideo.rawValue), localizedTitle: "Add Video…",
                    isDestructive: false),
    ContextMenuItem(id: ContextMenuItemID(id: GlowdropLink.library.rawValue), localizedTitle: "Open Glowdrop Library…",
                    isDestructive: false),
])

/// Built again (at most `attempts` builds in all) when the catalog changed during a build, so a reply never shows a
/// superseded catalog. SettingsPush passes 1: its own generation check already pushes again after a change.
@MainActor
func buildSettingsViewModelsXPC(attempts: Int = maxSettingsBuilds) async -> AnyObject? {
    let started = SurfaceStore.shared.catalog
    let models = await buildSettingsViewModelsOnce()
    guard attempts > 1, SurfaceStore.shared.catalog != started else { return models }
    wallpaperLog("[Settings] catalog changed during the build; building again")
    return await buildSettingsViewModelsXPC(attempts: attempts - 1)
}

/// One group, "Glowdrop": the follow tile, Shuffle, then one tile per catalog video. Served to both the desktop and
/// screen-saver pickers and remapped onto the private WallpaperSettingsViewModelsXPC.
@MainActor
private func buildSettingsViewModelsOnce() async -> AnyObject? {
    let provider = ChoiceProviderID(rawValue: Bundle.main.bundleIdentifier ?? "io.github.nimbusnuii.glowdrop.wallpaper")
    // The follow tile plays whatever the app mirrors, so it names no file (like Phosphene's shuffle choice).
    let follow = makeItem(provider: provider, identifier: WallpaperChoice.followID, files: [], name: groupName,
                          description: followDescription, thumbnail: await writeThumbnail(), sortOrder: 0)
    let videos = await catalogItems(provider: provider)
    let group = SettingsGroup(
        id: GroupID(id: groupID), items: [follow] + videos, localizedName: groupName,
        disposability: .none, sortOrder: -100, sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil, shouldHideItemLabels: false, contextMenu: tileMenu, thumbnail: nil
    )
    let viewModel = SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)
    return remapToRealXPC(SettingsViewModels(desktop: viewModel, screenSaver: viewModel))
}

/// A tile whose `configuration` is its identifier, which the acquire for that tile carries back.
private func makeItem(provider: ChoiceProviderID, identifier: String, files: [URL], name: String,
                      description: String, thumbnail: URL, sortOrder: Int) -> SettingsItem {
    let image = Thumbnail.image(url: thumbnail)
    let choiceID = ChoiceID(
        id: identifier,
        descriptor: ChoiceIDDescriptor(provider: provider, identifier: identifier, files: files,
                                       configuration: Data(identifier.utf8))
    )
    return SettingsItem(
        id: choiceID,
        localizedName: name,
        thumbnail: image,
        choice: ChoiceDescriptor(
            id: choiceID, provider: provider, identifier: identifier, name: name,
            localizedDescription: description, thumbnail: image,
            isDownloaded: true, options: []
        ),
        contentBadge: .video,
        showInTopLevel: true,
        sortOrder: sortOrder,
        disposability: .none,
        contextMenu: tileMenu
    )
}

/// Shuffle when the catalog lists two videos or more, then one tile per catalog video whose file is readable, in
/// catalog order.
@MainActor
private func catalogItems(provider: ChoiceProviderID) async -> [SettingsItem] {
    let catalog = SurfaceStore.shared.catalog?.items ?? []
    let videos = catalog.compactMap { item in
        LockScreenFiles.videoURL(named: item.file, in: WallpaperPaths.lockScreenDir).map { (item, $0) }
    }
    await makeCatalogThumbnails(videos.map { (item: $0.0, video: $0.1) })
    let shuffle: URL? = if catalog.count >= 2 { await shuffleThumbnail(for: catalog) } else { nil }
    // Last, so it never removes an image this build has just made, nor one of the catalog the store holds now: a
    // slower build of an older catalog keeps a newer revision's image; its own leftovers go on the next build.
    let current = SurfaceStore.shared.catalog?.items ?? []
    let shuffleNames = [catalog, current].filter { $0.count >= 2 }.map { shuffleThumbnailURL($0).lastPathComponent }
    removeStaleThumbnails(keeping: Set((catalog + current).map { catalogThumbnailURL($0).lastPathComponent }
        + shuffleNames))
    let tiles = videos.enumerated().map { index, entry in
        makeItem(provider: provider, identifier: entry.0.file, files: [entry.1], name: entry.0.title,
                 description: videoDescription, thumbnail: catalogThumbnailURL(entry.0), sortOrder: index + 2)
    }
    guard let shuffle else { return tiles }
    // Like the follow tile, it names no file: what it plays changes.
    return [makeItem(provider: provider, identifier: WallpaperChoice.shuffleID, files: [], name: shuffleName,
                     description: shuffleDescription, thumbnail: shuffle, sortOrder: 1)] + tiles
}

/// Off the main actor, at most four at a time.
private func makeCatalogThumbnails(_ videos: [(item: WallpaperCatalog.Item, video: URL)]) async {
    do {
        try FileManager.default.createDirectory(at: WallpaperPaths.thumbnailsDir, withIntermediateDirectories: true)
    } catch {
        wallpaperLog("[Settings] thumbnails folder failed:", privateDetail: error.localizedDescription)
        return
    }
    await withTaskGroup(of: Void.self) { group in
        for (index, entry) in videos.enumerated() {
            if index >= maxConcurrentThumbnails { _ = await group.next() }
            group.addTask { await catalogThumbnail(for: entry.item, video: entry.video) }
        }
    }
}

/// Removes every image whose name is not one of `names`: videos that left the catalog, and older revisions.
private func removeStaleThumbnails(keeping names: Set<String>) {
    let dir = WallpaperPaths.thumbnailsDir
    let fm = FileManager.default
    do {
        for name in try fm.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".png") && !names.contains(name) {
            try fm.removeItem(at: dir.appendingPathComponent(name))
        }
    } catch {
        wallpaperLog("[Settings] thumbnails cleanup failed:", privateDetail: error.localizedDescription)
    }
}

/// The revision is in the name, so System Settings, which caches images by URL, loads a replaced video's new one.
private func catalogThumbnailURL(_ item: WallpaperCatalog.Item) -> URL {
    WallpaperPaths.thumbnailsDir.appendingPathComponent("\(item.file).r\(item.updated).png")
}

/// `Thumbnails/shuffle.r<rev>.png`, `rev` hashed from the collage's videos' names and revisions, so a new one gets a
/// new URL.
private func shuffleThumbnailURL(_ items: [WallpaperCatalog.Item]) -> URL {
    let names = items.prefix(shuffleCollageItems).map { catalogThumbnailURL($0).lastPathComponent }
    return WallpaperPaths.thumbnailsDir
        .appendingPathComponent("shuffle.r\(LockScreenFiles.shortHash(names.joined(separator: "/"))).png")
}

/// Shuffle's tile image, made when missing: the first four catalog videos' tile images, 2×2, repeated in order when
/// there are fewer; a video without an image leaves its cell dark. Its URL either way: unwritten, the tile has none.
/// shortcut: a video whose tile image was missing when the collage was made stays dark in it until one of the four
/// videos changes; redraw collages with a dark cell if that shows up.
private func shuffleThumbnail(for items: [WallpaperCatalog.Item]) async -> URL {
    let target = shuffleThumbnailURL(items)
    guard !FileManager.default.fileExists(atPath: target.path) else { return target }
    // Downscaled on decode, so an oversized image planted under a tile image's name is never decoded whole.
    let options: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: Int(catalogThumbnailSize.width),
        kCGImageSourceCreateThumbnailFromImageAlways: true,
    ]
    let images = items.prefix(shuffleCollageItems).map { item -> CGImage? in
        CGImageSourceCreateWithURL(catalogThumbnailURL(item) as CFURL, nil)
            .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
    }
    guard let image = makeCollage(images), writePNG(image, to: target) else {
        wallpaperLog("[Settings] shuffle thumbnail not written; the tile has no image")
        return target
    }
    return target
}

/// `images` in a 2×2 grid the size of a catalog tile image, each filling its cell (cropped to its aspect).
private func makeCollage(_ images: [CGImage?]) -> CGImage? {
    let size = catalogThumbnailSize
    guard !images.isEmpty,
          let ctx = makeBitmapContext(width: Int(size.width), height: Int(size.height)) else { return nil }
    ctx.setFillColor(neutralDark)
    ctx.fill(CGRect(origin: .zero, size: size))
    let cell = CGSize(width: size.width / 2, height: size.height / 2)
    for index in 0..<shuffleCollageItems {
        guard let image = images[index % images.count] else { continue }
        // Row 0 on top: CoreGraphics counts y from the bottom.
        let frame = CGRect(x: CGFloat(index % 2) * cell.width, y: CGFloat(1 - index / 2) * cell.height,
                           width: cell.width, height: cell.height)
        let scale = max(cell.width / CGFloat(image.width), cell.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        ctx.saveGState()
        ctx.clip(to: frame)
        ctx.draw(image, in: CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2,
                                   width: drawn.width, height: drawn.height))
        ctx.restoreGState()
    }
    return ctx.makeImage()
}

/// `Thumbnails/<file>.r<updated>.png`: the video's first frame, made again only when missing or not stamped with the
/// video's modification date. shortcut: a frame that can't be read (or takes over 5 s) leaves the dark image until
/// the video changes; retry on every build if that shows up.
private func catalogThumbnail(for item: WallpaperCatalog.Item, video: URL) async {
    let target = catalogThumbnailURL(item)
    guard !isUpToDate(target, comparedTo: video) else { return }
    let frame = await firstFrame(of: video, maxSize: catalogThumbnailSize, timeout: thumbnailTimeout)
    guard let image = frame ?? makeSolidImage(neutralDark, width: 480, height: 270), writePNG(image, to: target) else {
        wallpaperLog("[Settings] thumbnail of \(item.file) not written; the tile has no image")
        return
    }
    stamp(target, from: video)
}

/// Gives the image its video's modification date, which `isUpToDate` compares.
private func stamp(_ thumbnail: URL, from video: URL) {
    do {
        guard let date = try video.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: thumbnail.path)
    } catch {
        wallpaperLog("[Settings] thumbnail date not set; it is made again next time:",
                     privateDetail: error.localizedDescription)
    }
}

/// False when either date can't be read, so the image is made again. Equal rather than newer, so a video dated in
/// the future is not redrawn on every build; within a millisecond, as setAttributes keeps only microseconds.
private func isUpToDate(_ thumbnail: URL, comparedTo video: URL) -> Bool {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey]
    guard let made = try? thumbnail.resourceValues(forKeys: keys).contentModificationDate,
          let changed = try? video.resourceValues(forKeys: keys).contentModificationDate else { return false }
    return abs(made.timeIntervalSince(changed)) < 0.001
}

/// The tile image, in the container: the current video's first frame, else the neutral dark image.
@MainActor
private func writeThumbnail() async -> URL {
    let target = WallpaperPaths.thumbnailURL
    let frame: CGImage? = if let url = SurfaceStore.shared.shownURL {
        await firstFrame(of: url, maxSize: thumbnailSize, timeout: thumbnailTimeout)
    } else {
        nil
    }
    do {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
        wallpaperLog("[Settings] thumbnail folder failed:", privateDetail: error.localizedDescription)
        return target
    }
    guard let image = frame ?? makeSolidImage(neutralDark, width: 480, height: 270), writePNG(image, to: target) else {
        wallpaperLog("[Settings] thumbnail write failed; the tile has no image")
        return target
    }
    return target
}

/// Archive via ShimViewModelsXPC and decode it back as the real XPC class.
/// Secure coding is off on purpose: the class substitution is the point, and the
/// archive never leaves this function (no untrusted input).
private func remapToRealXPC(_ viewModels: SettingsViewModels) -> AnyObject? {
    let data: Data
    do {
        data = try NSKeyedArchiver.archivedData(withRootObject: ShimViewModelsXPC(value: viewModels), requiringSecureCoding: false)
    } catch {
        wallpaperLog("[Remap] archive failed:", privateDetail: "\(error)")
        return nil
    }
    guard let realClass = objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass else {
        wallpaperLog("[Remap] WallpaperSettingsViewModelsXPC not found")
        return nil
    }
    let unarchiver: NSKeyedUnarchiver
    do {
        unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
    } catch {
        wallpaperLog("[Remap] unarchiver failed:", privateDetail: "\(error)")
        return nil
    }
    unarchiver.requiresSecureCoding = false
    unarchiver.decodingFailurePolicy = .setErrorAndReturn
    unarchiver.setClass(realClass, forClassName: "ShimViewModelsXPC")
    let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    if let error = unarchiver.error {
        wallpaperLog("[Remap] unarchive error:", privateDetail: "\(error)")
    }
    unarchiver.finishDecoding()
    return result as AnyObject?
}
