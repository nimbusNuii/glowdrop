// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.

import CoreGraphics
import Foundation

private let choiceIdentifier = "glowdrop"
private let choiceName = "Glowdrop"
private let thumbnailSize = CGSize(width: 640, height: 360)

/// One group with one choice, "Glowdrop", served to both the desktop and screen-saver pickers and
/// remapped onto the private WallpaperSettingsViewModelsXPC.
@MainActor
func buildSettingsViewModelsXPC() async -> AnyObject? {
    let name = choiceName
    let provider = ChoiceProviderID(rawValue: Bundle.main.bundleIdentifier ?? "io.github.nimbusnuii.glowdrop.wallpaper")
    let thumbnail = Thumbnail.image(url: await writeThumbnail())
    // The choice plays whatever the app mirrors, so it names no file (like Phosphene's shuffle choice).
    let choiceID = ChoiceID(
        id: choiceIdentifier,
        descriptor: ChoiceIDDescriptor(provider: provider, identifier: choiceIdentifier, files: [],
                                       configuration: Data(choiceIdentifier.utf8))
    )
    let item = SettingsItem(
        id: choiceID,
        localizedName: name,
        thumbnail: thumbnail,
        choice: ChoiceDescriptor(
            id: choiceID, provider: provider, identifier: choiceIdentifier, name: name,
            localizedDescription: name, thumbnail: thumbnail,
            isDownloaded: true, options: []
        ),
        contentBadge: .video,
        showInTopLevel: true,
        sortOrder: 0,
        disposability: .none,
        contextMenu: nil
    )
    let group = SettingsGroup(
        id: GroupID(id: choiceIdentifier), items: [item], localizedName: name,
        disposability: .none, sortOrder: -100, sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil, shouldHideItemLabels: false, contextMenu: nil, thumbnail: nil
    )
    let viewModel = SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)
    return remapToRealXPC(SettingsViewModels(desktop: viewModel, screenSaver: viewModel))
}

/// The tile image, in the container: the current video's first frame, else the neutral dark image.
@MainActor
private func writeThumbnail() async -> URL {
    let target = WallpaperPaths.thumbnailURL
    let frame: CGImage? = if let url = SurfaceStore.shared.shownURL {
        await firstFrame(of: url, maxSize: thumbnailSize)
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
