import Foundation

/// A resolution flavour of one wallpaper; `original` is a file without a resolution suffix.
enum VideoVariant: String, CaseIterable, Sendable {
    case original, twoK, fourK
}

enum QualityPreference: String, CaseIterable, Identifiable, Sendable {
    case auto, twoK, fourK
    var id: String { rawValue }
}

struct ParsedVideoName: Equatable, Sendable {
    let base: String
    let variant: VideoVariant
}

/// File names in one folder that share a base name, keyed by variant.
struct VideoGroup: Equatable, Sendable {
    let base: String
    let files: [VideoVariant: String]
    let thumbnail: String?
}

/// Pure file-name rules for the local library (no file system access).
enum LibraryNaming {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private static let thumbExtensions: Set<String> = ["png", "jpg"]
    private static let thumbSuffix = "-thumb"
    private static let resolutionSuffixes: [(String, VideoVariant)] = [
        ("-2160p", .fourK), ("-4k", .fourK), ("-1440p", .twoK), ("-1080p", .twoK), ("-2k", .twoK),
    ]

    /// Base name and variant of a video file; nil when the extension is not a supported video.
    static func parse(fileName: String) -> ParsedVideoName? {
        let name = fileName as NSString
        guard videoExtensions.contains(name.pathExtension.lowercased()) else { return nil }
        let stem = name.deletingPathExtension
        guard !stem.isEmpty else { return nil }
        for (suffix, variant) in resolutionSuffixes
        where stem.count > suffix.count && stem.suffix(suffix.count).lowercased() == suffix {
            return ParsedVideoName(base: String(stem.dropLast(suffix.count)), variant: variant)
        }
        return ParsedVideoName(base: stem, variant: .original)
    }

    /// Base name a `<base>-thumb.png|jpg` sidecar belongs to; nil for any other file.
    static func thumbnailBase(fileName: String) -> String? {
        let name = fileName as NSString
        guard thumbExtensions.contains(name.pathExtension.lowercased()) else { return nil }
        let stem = name.deletingPathExtension
        guard stem.count > thumbSuffix.count, stem.suffix(thumbSuffix.count).lowercased() == thumbSuffix else {
            return nil
        }
        return String(stem.dropLast(thumbSuffix.count))
    }

    /// Groups a folder's file names into wallpapers; on duplicate variants the first name in sort order wins.
    static func group(fileNames: [String]) -> [VideoGroup] {
        let sorted = fileNames.sorted()
        let thumbs = Dictionary(sorted.compactMap { name in thumbnailBase(fileName: name).map { ($0, name) } },
                                uniquingKeysWith: { first, _ in first })
        let files = sorted.reduce(into: [String: [VideoVariant: String]]()) { result, name in
            guard let parsed = parse(fileName: name), result[parsed.base]?[parsed.variant] == nil else { return }
            result[parsed.base, default: [:]][parsed.variant] = name
        }
        return files.map { VideoGroup(base: $0.key, files: $0.value, thumbnail: thumbs[$0.key]) }
            .sorted { $0.base < $1.base }
    }

    /// Bases listed in the sidecar `order` come first in that order; the rest follow in Finder order.
    static func ordered(_ bases: [String], by order: [String]) -> [String] {
        let present = Set(bases)
        var seen = Set<String>()
        let listed = order.filter { present.contains($0) && seen.insert($0).inserted }
        let rest = bases.filter { !seen.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return listed + rest
    }

    static func title(fromBase base: String) -> String {
        String(base.map { $0 == "-" || $0 == "_" ? " " : $0 })
    }

    /// True when `path` is a video the scanner would list: directly in a root or in one of its
    /// non-hidden subfolders (depth ≤ 1). A pure string check; `LibraryScanner.isLibraryFile` handles symlinks.
    static func isLibraryFile(path: String, roots: [String]) -> Bool {
        guard parse(fileName: (path as NSString).lastPathComponent) != nil else { return false }
        return roots.contains { root in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(prefix) else { return false }
            let components = path.dropFirst(prefix.count).split(separator: "/")
            return components.count <= 2 && !components.contains { $0.hasPrefix(".") }
        }
    }
}

enum VariantChooser {
    /// Backing pixel width from which Auto picks 4K; Retina 13–15" MacBooks (≤ 3024 px) stay on 2K.
    static let fourKMinPixelWidth: Double = 3200

    static func target(_ preference: QualityPreference, maxPixelWidth: Double, onBattery: Bool) -> VideoVariant {
        switch preference {
        case .auto: return maxPixelWidth >= fourKMinPixelWidth && !onBattery ? .fourK : .twoK
        case .twoK: return .twoK
        case .fourK: return .fourK
        }
    }

    /// The wanted variant if present, else the original, else the other resolution.
    static func choose(_ preference: QualityPreference, available: Set<VideoVariant>,
                       maxPixelWidth: Double, onBattery: Bool) -> VideoVariant? {
        let wanted = target(preference, maxPixelWidth: maxPixelWidth, onBattery: onBattery)
        let order: [VideoVariant] = wanted == .fourK ? [.fourK, .original, .twoK] : [.twoK, .original, .fourK]
        return order.first(where: available.contains)
    }
}
