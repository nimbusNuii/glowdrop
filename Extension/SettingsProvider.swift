// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.

import CoreGraphics
import Foundation

private let groupID = "glowdrop"
private let groupName = "Glowdrop"
private let followDescription = "Plays the wallpaper chosen in the Glowdrop app"
private let videoDescription = "Glowdrop video wallpaper"
private let thumbnailSize = CGSize(width: 640, height: 360)
private let catalogThumbnailSize = CGSize(width: 480, height: 270)
private let thumbnailTimeout: Duration = .seconds(5)
private let maxConcurrentThumbnails = 4

/// One group, "Glowdrop": the follow tile, then one tile per catalog video. Served to both the desktop and
/// screen-saver pickers and remapped onto the private WallpaperSettingsViewModelsXPC.
@MainActor
func buildSettingsViewModelsXPC() async -> AnyObject? {
    let provider = ChoiceProviderID(rawValue: Bundle.main.bundleIdentifier ?? "io.github.nimbusnuii.glowdrop.wallpaper")
    // The follow tile plays whatever the app mirrors, so it names no file (like Phosphene's shuffle choice).
    let follow = makeItem(provider: provider, identifier: WallpaperChoice.followID, files: [], name: groupName,
                          description: followDescription, thumbnail: await writeThumbnail(), sortOrder: 0)
    let videos = await catalogItems(provider: provider)
    let group = SettingsGroup(
        id: GroupID(id: groupID), items: [follow] + videos, localizedName: groupName,
        disposability: .none, sortOrder: -100, sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil, shouldHideItemLabels: false, contextMenu: nil, thumbnail: nil
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
        contextMenu: nil
    )
}

/// One tile per catalog video whose file is readable, in catalog order.
@MainActor
private func catalogItems(provider: ChoiceProviderID) async -> [SettingsItem] {
    let catalog = SurfaceStore.shared.catalog?.items ?? []
    let videos = catalog.compactMap { item in
        LockScreenFiles.videoURL(named: item.file, in: WallpaperPaths.lockScreenDir).map { (item, $0) }
    }
    await makeCatalogThumbnails(videos.map { (file: $0.0.file, video: $0.1) })
    // Last, so it never removes an image this build has just made.
    removeStaleThumbnails(keeping: Set(catalog.map(\.file)))
    return videos.enumerated().map { index, entry in
        makeItem(provider: provider, identifier: entry.0.file, files: [entry.1], name: entry.0.title,
                 description: videoDescription, thumbnail: catalogThumbnailURL(entry.0.file), sortOrder: index + 1)
    }
}

/// Off the main actor, at most four at a time.
private func makeCatalogThumbnails(_ videos: [(file: String, video: URL)]) async {
    do {
        try FileManager.default.createDirectory(at: WallpaperPaths.thumbnailsDir, withIntermediateDirectories: true)
    } catch {
        wallpaperLog("[Settings] thumbnails folder failed:", privateDetail: error.localizedDescription)
        return
    }
    await withTaskGroup(of: Void.self) { group in
        for (index, entry) in videos.enumerated() {
            if index >= maxConcurrentThumbnails { _ = await group.next() }
            group.addTask { await catalogThumbnail(for: entry.file, video: entry.video) }
        }
    }
}

/// Removes the images of videos that left the catalog.
private func removeStaleThumbnails(keeping files: Set<String>) {
    let dir = WallpaperPaths.thumbnailsDir
    let fm = FileManager.default
    do {
        for name in try fm.contentsOfDirectory(atPath: dir.path)
            where name.hasSuffix(".png") && !files.contains((name as NSString).deletingPathExtension) {
            try fm.removeItem(at: dir.appendingPathComponent(name))
        }
    } catch {
        wallpaperLog("[Settings] thumbnails cleanup failed:", privateDetail: error.localizedDescription)
    }
}

private func catalogThumbnailURL(_ file: String) -> URL {
    WallpaperPaths.thumbnailsDir.appendingPathComponent(file + ".png")
}

/// `Thumbnails/<file>.png`: the video's first frame, made again only when missing or not stamped with the video's
/// modification date. shortcut: a frame that can't be read (or takes over 5 s) leaves the dark image until the
/// video changes; retry on every build if that shows up.
private func catalogThumbnail(for file: String, video: URL) async {
    let target = catalogThumbnailURL(file)
    guard !isUpToDate(target, comparedTo: video) else { return }
    let frame = await firstFrame(of: video, maxSize: catalogThumbnailSize, timeout: thumbnailTimeout)
    guard let image = frame ?? makeSolidImage(neutralDark, width: 480, height: 270), writePNG(image, to: target) else {
        wallpaperLog("[Settings] thumbnail of \(file) not written; the tile has no image")
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
