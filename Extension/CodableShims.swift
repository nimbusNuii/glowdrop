// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.
//
// Codable mirrors of WallpaperTypes' settings view models, trimmed to what one
// static choice needs. Encoded via NSKeyedArchiver and re-decoded as the private
// WallpaperSettingsViewModelsXPC (see SettingsProvider.swift).

import Foundation

struct SettingsViewModels: Codable {
    var desktop: SettingsViewModel?
    var screenSaver: SettingsViewModel?
}

struct SettingsViewModel: Codable {
    var groups: [SettingsGroup]
    var refreshPolicy: RefreshPolicy
    var isModificationDisabled: Bool
}

struct SettingsGroup: Codable {
    var id: GroupID
    var items: [SettingsItem]
    var localizedName: String
    var disposability: Disposability
    var sortOrder: Int
    var sortID: GroupSortID?
    var allChoiceID: ChoiceID?
    var shouldHideItemLabels: Bool?
    var contextMenu: ContextMenu?
    var thumbnail: Data?
}

struct GroupID: Codable { var id: String }
struct GroupSortID: Codable { var id: String }

struct ChoiceID: Codable {
    var id: String
    var descriptor: ChoiceIDDescriptor
}

struct ChoiceIDDescriptor: Codable {
    var provider: ChoiceProviderID
    var identifier: String
    var files: [URL]
    var configuration: Data
}

struct SettingsItem: Codable {
    var id: ChoiceID
    var localizedName: String
    var thumbnail: Thumbnail
    var choice: ChoiceDescriptor
    var contentBadge: ContentBadge
    var showInTopLevel: Bool
    var sortOrder: Int
    var disposability: Disposability
    var contextMenu: ContextMenu?
}

struct ChoiceDescriptor: Codable {
    var id: ChoiceID
    var provider: ChoiceProviderID
    var identifier: String
    var name: String?
    var localizedDescription: String
    var thumbnail: Thumbnail
    var isDownloaded: Bool
    /// shortcut: always empty, so the element type is a stand-in for WallpaperOptionEnum;
    /// port Phosphene's WallpaperOption if per-choice pickers are ever needed.
    var options: [String]
}

struct ContextMenu: Codable { var items: [ContextMenuItem] }

struct ContextMenuItem: Codable {
    var id: ContextMenuItemID
    var localizedTitle: String
    var isDestructive: Bool
}

struct ContextMenuItemID: Codable { var id: String }

/// Encodes as a plain string (singleValueContainer).
struct ChoiceProviderID: Codable {
    var rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
}

enum EmptyCodingKeys: CodingKey {}

/// Payload-less enum cases encode as `{ caseName: {} }`, matching Swift's synthesized enum Codable.
private func encodeBareCase<K: CodingKey>(_ key: K, to encoder: any Encoder) {
    var container = encoder.container(keyedBy: K.self)
    _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: key)
}

/// WallpaperTypes.WallpaperDisposability (none / removable / purgeable). Only `none` is used.
enum Disposability: Codable {
    case none

    private enum CodingKeys: String, CodingKey { case none }

    func encode(to encoder: any Encoder) throws { encodeBareCase(CodingKeys.none, to: encoder) }
    init(from _: any Decoder) throws { self = .none }
}

/// WallpaperSettingsItem.ContentBadge (none / video / dynamic). Only `video` is used.
enum ContentBadge: Codable {
    case video

    private enum CodingKeys: String, CodingKey { case video }

    func encode(to encoder: any Encoder) throws { encodeBareCase(CodingKeys.video, to: encoder) }
    init(from _: any Decoder) throws { self = .video }
}

enum RefreshPolicy: Codable {
    case `default`

    private enum CodingKeys: String, CodingKey { case `default` }

    func encode(to encoder: any Encoder) throws { encodeBareCase(CodingKeys.default, to: encoder) }
    init(from _: any Decoder) throws { self = .default }
}

/// WallpaperThumbnail. Only the `.image(url:)` case is modelled.
enum Thumbnail: Codable {
    case image(url: URL)

    private enum CodingKeys: String, CodingKey { case image }
    private enum ImageCodingKeys: String, CodingKey { case url }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .image(url):
            var nested = container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
            try nested.encode(url, forKey: .url)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
        self = try .image(url: nested.decode(URL.self, forKey: .url))
    }
}

/// NSObject wrapper that archives SettingsViewModels under the real XPC type's key.
@objc(ShimViewModelsXPC)
final class ShimViewModelsXPC: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let value: SettingsViewModels

    init(value: SettingsViewModels) {
        self.value = value
        super.init()
    }

    required init?(coder _: NSCoder) {
        nil // never decoded as itself; the unarchiver substitutes the real class
    }

    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else {
            wallpaperLog("[ShimXPC] encode error: coder is not NSKeyedArchiver")
            return
        }
        do {
            try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
        } catch {
            wallpaperLog("[ShimXPC] encode error:", privateDetail: "\(error)")
        }
    }
}
