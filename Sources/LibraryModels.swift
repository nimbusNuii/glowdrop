import Foundation

struct LibraryItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// Folder name; empty for files directly in a library root ("Other").
    let category: String
    let variants: [VideoVariant: URL]
    let thumbnail: URL?
    let isDefault: Bool

    var has4K: Bool { variants[.fourK] != nil }
    /// Smallest file available, used for generated thumbnails and "Show in Finder".
    var previewURL: URL? { variants[.twoK] ?? variants[.original] ?? variants[.fourK] }

    /// True when `path` is one of this wallpaper's files; false for nil.
    func hasFile(atPath path: String?) -> Bool { variants.values.contains { $0.path == path } }
}

struct LibraryCategory: Identifiable, Hashable, Sendable {
    /// Empty name = files directly in a library root ("Other").
    let name: String
    let items: [LibraryItem]
    var id: String { name }
}

enum ScanWarning: Equatable, Sendable {
    case badSidecar(folder: String)
    case unreadableFolder(String)
}

struct LibraryScanResult: Sendable {
    let categories: [LibraryCategory]
    let defaultItem: LibraryItem?
    let warnings: [ScanWarning]
    /// Error text when the library root itself could not be read.
    let rootError: String?
}

/// Optional per-folder `wallpapers.json`.
struct WallpaperSidecar: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let title: String?
        let isDefault: Bool?

        enum CodingKeys: String, CodingKey {
            case title
            case isDefault = "default"
        }
    }

    let order: [String]?
    let items: [String: Entry]?
}
