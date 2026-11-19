import Foundation

/// Reads the library folders from disk. Runs off the main thread; touches no UI state.
enum LibraryScanner {
    static let sidecarName = "wallpapers.json"
    static let maxSidecarBytes = 64 * 1024
    static let maxTitleLength = 80

    private struct RootScan {
        static let empty = RootScan(categories: [], warnings: [])
        let categories: [LibraryCategory]
        let warnings: [ScanWarning]
    }

    private struct FolderScan {
        let category: LibraryCategory
        let warning: ScanWarning?
    }

    static func scan(libraryRoot: URL, createIfMissing: Bool, bundledRoot: URL?) -> LibraryScanResult {
        let library: RootScan
        let rootError: String?
        do {
            if createIfMissing {
                try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            }
            library = try scanRoot(libraryRoot)
            rootError = nil
        } catch {
            library = .empty
            rootError = error.localizedDescription
        }
        let bundled = scanBundled(bundledRoot)
        let ordered = library.categories + bundled.categories
        let defaultItem = ordered.flatMap(\.items).first(where: \.isDefault)
        return LibraryScanResult(categories: sortCategories(merge(ordered), defaultCategory: defaultItem?.category),
                                 defaultItem: defaultItem,
                                 warnings: library.warnings + bundled.warnings,
                                 rootError: rootError)
    }

    /// True when the scanner would list `url` under one of `roots`. Paths are checked as given and with symlinks
    /// resolved, so a file opened through a symlinked subfolder counts as well as one under a linked root.
    static func isLibraryFile(_ url: URL, roots: [URL]) -> Bool {
        let rootPaths = roots.flatMap { [$0.path, $0.resolvingSymlinksInPath().path] }
        return [url.path, url.resolvingSymlinksInPath().path].contains {
            LibraryNaming.isLibraryFile(path: $0, roots: rootPaths)
        }
    }

    /// Sidebar order: the default wallpaper's category first, the rest alphabetically, "Other" (empty name) last.
    static func sortCategories(_ categories: [LibraryCategory], defaultCategory: String?) -> [LibraryCategory] {
        func rank(_ name: String) -> Int { name == defaultCategory ? 0 : name.isEmpty ? 2 : 1 }
        return categories.sorted {
            rank($0.name) != rank($1.name) ? rank($0.name) < rank($1.name)
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The bundled folder is optional; a missing one is not an error.
    private static func scanBundled(_ root: URL?) -> RootScan {
        guard let root, FileManager.default.fileExists(atPath: root.path) else { return .empty }
        do {
            return try scanRoot(root)
        } catch {
            return RootScan(categories: [], warnings: [.unreadableFolder(root.lastPathComponent)])
        }
    }

    private static func scanRoot(_ root: URL) throws -> RootScan {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let resolvedRoot = root.resolvingSymlinksInPath().path
        // Symlinked folders are followed once (still depth 1); links back to the root or above it are skipped.
        let folders = entries.filter { isDirectory($0.resolvingSymlinksInPath()) }
            .filter { !isRootOrAncestor($0.resolvingSymlinksInPath().path, of: resolvedRoot) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let rootFiles = entries.filter { !isDirectory($0.resolvingSymlinksInPath()) }.map(\.lastPathComponent)
        let rootScan = scanFolder(root, fileNames: rootFiles, category: "")
        let subfolderScans = folders.map(scanSubfolder)
        let categories = subfolderScans.map(\.category) + (rootScan.category.items.isEmpty ? [] : [rootScan.category])
        return RootScan(categories: categories, warnings: (subfolderScans + [rootScan]).compactMap(\.warning))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRootOrAncestor(_ path: String, of root: String) -> Bool {
        path == root || root.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }

    private static func scanSubfolder(_ folder: URL) -> FolderScan {
        let name = folder.lastPathComponent
        do {
            let fileNames = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { !$0.hasPrefix(".") }
            return scanFolder(folder, fileNames: fileNames, category: name)
        } catch {
            return FolderScan(category: LibraryCategory(name: name, items: []), warning: .unreadableFolder(name))
        }
    }

    private static func scanFolder(_ folder: URL, fileNames: [String], category: String) -> FolderScan {
        let sidecar = readSidecar(in: folder, present: fileNames.contains(sidecarName))
        let groups = LibraryNaming.group(fileNames: fileNames)
        let byBase = Dictionary(uniqueKeysWithValues: groups.map { ($0.base, $0) })
        let bases = LibraryNaming.ordered(groups.map(\.base), by: sidecar.value?.order ?? [])
        let items = bases.compactMap { byBase[$0] }.map { group in
            makeItem(group, folder: folder, category: category, entry: sidecar.value?.items?[group.base])
        }
        let warning: ScanWarning? = sidecar.isMalformed ? .badSidecar(folder: folder.lastPathComponent) : nil
        return FolderScan(category: LibraryCategory(name: category, items: items), warning: warning)
    }

    private static func readSidecar(in folder: URL, present: Bool) -> (value: WallpaperSidecar?, isMalformed: Bool) {
        guard present else { return (nil, false) }
        do {
            let url = folder.appendingPathComponent(sidecarName)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= maxSidecarBytes else {
                return (nil, true)
            }
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(WallpaperSidecar.self, from: data), false)
        } catch {
            return (nil, true)
        }
    }

    private static func makeItem(_ group: VideoGroup, folder: URL, category: String,
                                 entry: WallpaperSidecar.Entry?) -> LibraryItem {
        LibraryItem(id: folder.appendingPathComponent(group.base).path,
                    title: entry?.title.map(clampTitle) ?? LibraryNaming.title(fromBase: group.base),
                    category: category,
                    variants: group.files.mapValues { folder.appendingPathComponent($0) },
                    thumbnail: group.thumbnail.map { folder.appendingPathComponent($0) },
                    isDefault: entry?.isDefault == true)
    }

    private static func clampTitle(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleLength))
    }

    /// Same-named categories from the library and the bundle become one (library items first).
    private static func merge(_ categories: [LibraryCategory]) -> [LibraryCategory] {
        var names: [String] = []
        var itemsByName: [String: [LibraryItem]] = [:]
        for category in categories {
            if itemsByName[category.name] == nil { names.append(category.name) }
            itemsByName[category.name, default: []] += category.items
        }
        return names.map { LibraryCategory(name: $0, items: itemsByName[$0] ?? []) }
    }
}
