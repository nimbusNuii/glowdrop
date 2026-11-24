import CryptoKit
import Foundation

/// What the app tells the wallpaper extension: which file in the LockScreen folder to play, and how.
struct LockScreenState: Codable, Equatable, Sendable {
    let file: String
    let updated: Int
    let flags: PlaybackFlags

    init(file: String, updated: Int, flags: PlaybackFlags = PlaybackFlags()) {
        self.file = file
        self.updated = updated
        self.flags = flags
    }

    private enum CodingKeys: String, CodingKey { case file, updated }

    /// The flags sit beside `file` and `updated` in one flat JSON object.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        file = try values.decode(String.self, forKey: .file)
        updated = try values.decode(Int.self, forKey: .updated)
        flags = try PlaybackFlags(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(file, forKey: .file)
        try values.encode(updated, forKey: .updated)
        try flags.encode(to: encoder)
    }
}

/// How the extension plays, as the app's settings say.
struct PlaybackFlags: Codable, Equatable, Sendable {
    /// The extension also plays desktop surfaces, not only the Lock Screen.
    let desktop: Bool
    /// The user paused playback in the app.
    let paused: Bool
    let pauseInLowPowerMode: Bool
    let pauseOnBattery: Bool
    /// Hold a still image while macOS's Reduce Motion is on.
    let pauseWithReduceMotion: Bool
    /// Displays whose desktop windows cover completely; their desktop surfaces hold a still. Empty when the
    /// "pause when covered" setting is off.
    let coveredDisplays: [UInt32]
    /// Seconds between the Shuffle tile's videos: always one of `shuffleIntervals`.
    let shuffleInterval: Int

    static let shuffleIntervals = [300, 900, 3_600, 86_400]
    static let defaultShuffleInterval = 900

    init(desktop: Bool = false, paused: Bool = false, pauseInLowPowerMode: Bool = true, pauseOnBattery: Bool = false,
         pauseWithReduceMotion: Bool = true, coveredDisplays: [UInt32] = [],
         shuffleInterval: Int = PlaybackFlags.defaultShuffleInterval) {
        self.desktop = desktop
        self.paused = paused
        self.pauseInLowPowerMode = pauseInLowPowerMode
        self.pauseOnBattery = pauseOnBattery
        self.pauseWithReduceMotion = pauseWithReduceMotion
        self.coveredDisplays = coveredDisplays
        self.shuffleInterval = Self.validShuffleInterval(shuffleInterval)
    }

    /// `seconds` when it is one of `shuffleIntervals`, else the default.
    static func validShuffleInterval(_ seconds: Int) -> Int {
        shuffleIntervals.contains(seconds) ? seconds : defaultShuffleInterval
    }

    /// These flags with no display covered.
    var uncovered: PlaybackFlags {
        PlaybackFlags(desktop: desktop, paused: paused, pauseInLowPowerMode: pauseInLowPowerMode,
                      pauseOnBattery: pauseOnBattery, pauseWithReduceMotion: pauseWithReduceMotion,
                      shuffleInterval: shuffleInterval)
    }

    /// Every key is optional, so a 0.2.0 state.json (file and updated only) reads with the defaults. A 0.4.0 key of
    /// the wrong JSON type reads as its default rather than losing the whole state.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PlaybackFlags()
        desktop = try values.decodeIfPresent(Bool.self, forKey: .desktop) ?? defaults.desktop
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? defaults.paused
        pauseInLowPowerMode = try values.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode)
            ?? defaults.pauseInLowPowerMode
        pauseOnBattery = try values.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? defaults.pauseOnBattery
        pauseWithReduceMotion = try values.decodeIfPresent(Bool.self, forKey: .pauseWithReduceMotion)
            ?? defaults.pauseWithReduceMotion
        coveredDisplays = (try? values.decodeIfPresent([UInt32].self, forKey: .coveredDisplays))
            ?? defaults.coveredDisplays
        shuffleInterval = Self.validShuffleInterval((try? values.decodeIfPresent(Int.self, forKey: .shuffleInterval))
            ?? defaults.shuffleInterval)
    }
}

/// The videos the extension offers besides the one the app plays: clones the app keeps in the LockScreen folder.
struct WallpaperCatalog: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let file: String
        let title: String
        /// The clone's modification date in milliseconds since 1970 (a clone keeps its source's date), so a video
        /// replaced under the same name gets a new tile image and still.
        let updated: Int
        /// The clone to play on battery power, in Low Power Mode or while the Mac is warm (the variant Auto quality
        /// picks on battery); nil when that is `file` itself. `updated` stays `file`'s revision.
        let batteryFile: String?

        init(file: String, title: String, updated: Int = 0, batteryFile: String? = nil) {
            self.file = file
            self.title = title
            self.updated = updated
            self.batteryFile = batteryFile
        }

        /// A 0.3.0 catalog has no `updated`, and no 0.3.x catalog has `batteryFile`: its items read as revision 0
        /// with no battery clone. A `batteryFile` of the wrong JSON type reads as none, and the item stays.
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            file = try values.decode(String.self, forKey: .file)
            title = try values.decode(String.self, forKey: .title)
            updated = try values.decodeIfPresent(Int.self, forKey: .updated) ?? 0
            batteryFile = try? values.decodeIfPresent(String.self, forKey: .batteryFile)
        }
    }

    let items: [Item]
}

/// A video the app lists in catalog.json, with the title the extension shows for it.
struct CatalogSource: Sendable {
    let source: URL
    let title: String
    /// The variant for battery power, when it is another file than `source`.
    let batterySource: URL?

    init(source: URL, title: String, batterySource: URL? = nil) {
        self.source = source
        self.title = title
        self.batterySource = batterySource
    }
}

/// What a sync could not do without failing as a whole.
struct SyncReport: Sendable, Equatable {
    /// Catalog sources whose clone failed, each battery variant counted on its own; sources skipped on purpose
    /// (another volume, no cloning, an unsupported type, a missing file) are not counted.
    let failedCatalogItems: Int
}

enum LockScreenFilesError: Error, Equatable {
    /// The source's extension is not one the Lock Screen plays (mp4, mov, m4v).
    case unsupportedType(String)
    /// The LockScreen volume has less than the source's size plus the safety margin free.
    case insufficientSpace(neededBytes: Int64)
    /// The LockScreen folder is a symlink, sits under one, or is not a directory.
    case folderIsNotADirectory
}

/// The LockScreen folder contract between the app (writer) and the wallpaper extension (reader).
/// Foundation only: it is compiled into the app, the extension and the selftests.
enum LockScreenFiles {
    static let stateName = "state.json"
    static let maxStateBytes = 4 * 1024
    static let catalogName = "catalog.json"
    static let maxCatalogBytes = 256 * 1024
    static let maxCatalogItems = 200
    static let maxTitleLength = 80
    static let maxTitleScalars = 160
    /// A longer cluster is a stack of combining marks, not a letter anyone reads.
    static let maxScalarsPerCharacter = 8
    /// Invisible or reorderable text (bidi overrides, zero-width marks) that could make a title lie about its file.
    private static let hiddenCategories: Set<Unicode.GeneralCategory> = [
        .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned,
    ]
    /// Same types as LibraryNaming.videoExtensions; the extension plays nothing else.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// Free space kept on the volume after a copy, so the Lock Screen video never fills the disk.
    static let copyMarginBytes: Int64 = 512 * 1024 * 1024
    private static let videoPrefix = "video-"
    private static let partialPrefix = ".partial-"
    private static let hashLength = 16
    private static let hexDigits = Set("0123456789abcdef")

    // MARK: Names

    /// "video-<first 16 hex of SHA-256(path)>.<ext>": stable for one source path, never a name a user picks.
    /// nil when the extension is not mp4, mov or m4v.
    static func videoName(forSourcePath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard videoExtensions.contains(ext) else { return nil }
        return "\(videoPrefix)\(shortHash(path)).\(ext)"
    }

    /// The first 16 hex digits of SHA-256 over `text`'s UTF-8.
    static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(hashLength / 2).map { String(format: "%02x", $0) }.joined()
    }

    /// True only for names `videoName` makes, so "/", ".." and the user's own files never match.
    static func isVideoName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let stem = parts.first, stem.hasPrefix(videoPrefix) else { return false }
        let hex = stem.dropFirst(videoPrefix.count)
        return hex.count == hashLength && hex.allSatisfy(hexDigits.contains) && videoExtensions.contains(String(parts[1]))
    }

    /// Files the app created that `keep` no longer needs (old videos, interrupted copies); anything else stays.
    static func staleFiles(in names: [String], keeping keep: Set<String>) -> [String] {
        names.filter { name in
            let video = name.hasPrefix(partialPrefix) ? String(name.dropFirst(partialPrefix.count)) : name
            return !keep.contains(name) && isVideoName(video)
        }
    }

    static func isEnoughSpace(sourceBytes: Int64, availableBytes: Int64) -> Bool {
        availableBytes >= sourceBytes + copyMarginBytes
    }

    // MARK: state.json

    static func encode(_ state: LockScreenState) throws -> Data {
        try sortedJSON(state)
    }

    /// nil when the data is over 4 KB, is not a state, or names a file the app would never write.
    static func decode(_ data: Data) -> LockScreenState? {
        guard data.count <= maxStateBytes,
              let state = try? JSONDecoder().decode(LockScreenState.self, from: data),
              isVideoName(state.file) else { return nil }
        return state
    }

    /// nil when absent or invalid; see `readSmallFile`.
    static func readState(in folder: URL) -> LockScreenState? {
        readSmallFile(named: stateName, in: folder, maxBytes: maxStateBytes).flatMap(decode)
    }

    /// The state's video; see `videoURL(named:in:)`.
    static func videoURL(for state: LockScreenState, in folder: URL) -> URL? {
        videoURL(named: state.file, in: folder)
    }

    /// The video, only if it is a readable regular file directly inside `folder`. A symlink is refused: the app never
    /// makes one, so it could only point somewhere the app did not choose.
    static func videoURL(named file: String, in folder: URL) -> URL? {
        guard isVideoName(file) else { return nil }
        let root = folder.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(file)
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink == false, values.isRegularFile == true,
              url.deletingLastPathComponent().path == root.path,
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    // MARK: catalog.json

    static func encodeCatalog(_ catalog: WallpaperCatalog) throws -> Data {
        try sortedJSON(catalog)
    }

    /// nil when the data is over 256 KB or is not a catalog. Keeps the first 200 distinct names the app would write,
    /// in order, with titles safe to show; a battery clone only under a name the app would write.
    static func decodeCatalog(_ data: Data) -> WallpaperCatalog? {
        guard data.count <= maxCatalogBytes,
              let catalog = try? JSONDecoder().decode(WallpaperCatalog.self, from: data) else { return nil }
        var files = Set<String>()
        let items = catalog.items.filter { isVideoName($0.file) && files.insert($0.file).inserted }
        return WallpaperCatalog(items: items.prefix(maxCatalogItems).map {
            WallpaperCatalog.Item(file: $0.file, title: displayTitle($0.title, file: $0.file), updated: $0.updated,
                                  batteryFile: $0.batteryFile.flatMap { isVideoName($0) ? $0 : nil })
        })
    }

    /// nil when absent or invalid; see `readSmallFile`.
    static func readCatalog(in folder: URL) -> WallpaperCatalog? {
        readSmallFile(named: catalogName, in: folder, maxBytes: maxCatalogBytes).flatMap(decodeCatalog)
    }

    /// Without hidden characters, line breaks or overlong clusters, trimmed, at most 80 characters and 160 scalars;
    /// the file's stem when that is empty.
    private static func displayTitle(_ title: String, file: String) -> String {
        let visible = String(title.unicodeScalars.filter {
            !hiddenCategories.contains($0.properties.generalCategory) && !CharacterSet.newlines.contains($0)
        }).filter { $0.unicodeScalars.count <= maxScalarsPerCharacter }
        var scalars = 0
        let capped = String(visible.trimmingCharacters(in: .whitespaces).prefix(maxTitleLength).prefix {
            scalars += $0.unicodeScalars.count
            return scalars <= maxTitleScalars
        })
        return capped.isEmpty ? (file as NSString).deletingPathExtension : capped
    }

    /// Opens without following a symlink and without blocking on a FIFO, and reads only a regular file of at most
    /// `maxBytes`.
    private static func readSmallFile(named name: String, in folder: URL, maxBytes: Int) -> Data? {
        let fd = open(folder.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxBytes else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try? handle.read(upToCount: maxBytes + 1)
    }

    private static func sortedJSON(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    // MARK: Writing (app side)

    /// Puts `current` in `folder` and writes state.json, then clones the catalog's sources and battery variants
    /// (symlinks resolved) and writes catalog.json (removed when `catalog` is nil), then removes what they replaced. A
    /// file lands before the JSON that names it, and a failed catalog clone can never hold back state.json. `current`
    /// is an instant clone on the same APFS volume and a full copy otherwise; catalog sources are only ever cloned.
    @discardableResult
    static func sync(current: URL, flags: PlaybackFlags, catalog: [CatalogSource]?, into folder: URL,
                     now: Date = Date()) throws -> SyncReport {
        let current = current.resolvingSymlinksInPath()
        guard let name = videoName(forSourcePath: current.path) else {
            throw LockScreenFilesError.unsupportedType(current.pathExtension.lowercased())
        }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard isRealDirectory(folder) else { throw LockScreenFilesError.folderIsNotADirectory }
        let copied = try copyIfChanged(current, to: folder.appendingPathComponent(name))
        try writeState(file: name, flags: flags, copied: copied, in: folder, now: now)
        let clones = catalog.map { cloneCatalog($0, into: folder) }
        if let clones {
            try writeIfChanged(encodeCatalog(WallpaperCatalog(items: clones.items)), named: catalogName, in: folder)
        } else {
            try removeIfPresent(catalogName, in: folder)
        }
        let keep = Set([name] + (clones?.items ?? []).flatMap { [$0.file, $0.batteryFile].compactMap { $0 } })
        try removeFiles(staleFiles(in: fm.contentsOfDirectory(atPath: folder.path), keeping: keep), in: folder)
        return SyncReport(failedCatalogItems: clones?.failed ?? 0)
    }

    /// Removes state.json first (the extension then shows nothing), then catalog.json and every video the app created.
    /// Does nothing unless `folder` is a real directory, so a symlinked folder never deletes anything elsewhere.
    static func clear(_ folder: URL) throws {
        guard isRealDirectory(folder) else { return }
        try removeIfPresent(stateName, in: folder)
        try removeIfPresent(catalogName, in: folder)
        try removeFiles(staleFiles(in: FileManager.default.contentsOfDirectory(atPath: folder.path), keeping: []),
                        in: folder)
    }

    /// At most 200 distinct clones, in order; a source that cannot be cloned loses its tile, never the whole sync, and
    /// a battery variant that cannot be cloned leaves its tile on the main clone alone.
    private static func cloneCatalog(_ sources: [CatalogSource],
                                     into folder: URL) -> (items: [WallpaperCatalog.Item], failed: Int) {
        // shortcut: no tiles on a volume without cloning (HFS+), where each would be a full copy; upgrade if asked.
        guard (try? folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?
            .volumeSupportsFileCloning == true else { return ([], 0) }
        var items: [WallpaperCatalog.Item] = []
        var files = Set<String>()
        var failed = 0
        for entry in sources where items.count < maxCatalogItems {
            do {
                guard let file = try cloneCatalogSource(entry.source, into: folder),
                      files.insert(file).inserted else { continue }
                let battery = Result { try entry.batterySource.flatMap { try cloneCatalogSource($0, into: folder) } }
                if case .failure = battery { failed += 1 }
                items.append(WallpaperCatalog.Item(file: file, title: entry.title,
                                                   updated: revision(of: folder.appendingPathComponent(file)),
                                                   batteryFile: try? battery.get()))
            } catch {
                // copyIfChanged already removed the partial file; the caller reports the count.
                failed += 1
            }
        }
        return (items, failed)
    }

    /// The clone's modification date in whole milliseconds since 1970, which it keeps from its source: a source
    /// replaced under the same name gets a new revision, an untouched one keeps it, even across a crash between the
    /// clone and catalog.json. 0 when the date can't be read (or is out of range).
    private static func revision(of clone: URL) -> Int {
        guard let date = try? clone.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return 0 }
        return Int(exactly: (date.timeIntervalSince1970 * 1000).rounded(.down)) ?? 0
    }

    /// The clone's name; nil when the source is not a supported regular file on the folder's volume. Throws when
    /// the copy fails.
    private static func cloneCatalogSource(_ source: URL, into folder: URL) throws -> String? {
        let source = source.resolvingSymlinksInPath()
        // shortcut: a video on another volume gets no tile (no multi-GB copies), upgrade if users ask for those tiles.
        guard let name = videoName(forSourcePath: source.path),
              (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              isSameVolume(source, folder) else { return nil }
        _ = try copyIfChanged(source, to: folder.appendingPathComponent(name))
        return name
    }

    /// Rewrites state.json with its flags passed through `change`, keeping its file and `updated` so the extension does
    /// not restart the video. Writes nothing when the folder holds no valid state.json or the flags stay the same.
    static func updateFlags(in folder: URL, _ change: (PlaybackFlags) -> PlaybackFlags) throws {
        guard isRealDirectory(folder), let state = readState(in: folder) else { return }
        let flags = change(state.flags)
        guard flags != state.flags else { return }
        try encode(LockScreenState(file: state.file, updated: state.updated, flags: flags))
            .write(to: folder.appendingPathComponent(stateName), options: .atomic)
    }

    /// The same file keeps its `updated`, so the extension does not restart the video; the flags always follow the app.
    private static func writeState(file: String, flags: PlaybackFlags, copied: Bool, in folder: URL, now: Date) throws {
        let kept = copied ? nil : readState(in: folder).flatMap { $0.file == file ? $0.updated : nil }
        let state = LockScreenState(file: file, updated: kept ?? Int(now.timeIntervalSince1970), flags: flags)
        try writeIfChanged(encode(state), named: stateName, in: folder)
    }

    /// Atomic, and only when the bytes differ (a larger file differs anyway), so the extension wakes only on a change.
    private static func writeIfChanged(_ data: Data, named name: String, in folder: URL) throws {
        guard readSmallFile(named: name, in: folder, maxBytes: data.count) != data else { return }
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// Copies to a hidden partial file and renames it into place, so a reader never opens half a video.
    /// False when `dest` already holds this file (same size and modification date).
    private static func copyIfChanged(_ source: URL, to dest: URL) throws -> Bool {
        let fm = FileManager.default
        // A directory or symlink under our name is never a copy we made; it goes before it can pass as this file.
        if let type = entryType(dest), type != S_IFREG { try fm.removeItem(at: dest) }
        guard !isSameFile(source, dest) else { return false }
        let folder = dest.deletingLastPathComponent()
        let partial = folder.appendingPathComponent(partialPrefix + dest.lastPathComponent)
        // Before the space check, so a crashed multi-GB partial is not counted as used space. lstat, so a planted
        // dangling symlink (which fileExists misses) goes too.
        if entryType(partial) != nil { try fm.removeItem(at: partial) }
        // On one volume copyItem clones (APFS) and needs almost no space.
        if !isSameVolume(source, folder) { try requireFreeSpace(for: source, in: folder) }
        do {
            try fm.copyItem(at: source, to: partial)
            guard rename(partial.path, dest.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            // The copy error is the one reported; a partial that survives this is removed by the next sync or clear.
            try? fm.removeItem(at: partial)
            throw error
        }
        return true
    }

    /// A volume that reports no available capacity is not checked.
    private static func requireFreeSpace(for source: URL, in folder: URL) throws {
        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        guard isEnoughSpace(sourceBytes: size, availableBytes: available) else {
            throw LockScreenFilesError.insufficientSpace(neededBytes: size + copyMarginBytes)
        }
    }

    /// False when either volume identifier is unknown, so the free-space check stays on.
    static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject,
              let y = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return false }
        return x.isEqual(y)
    }

    /// The entry's own type (S_IFREG, S_IFDIR, S_IFLNK, …), a symlink not followed; nil when there is none.
    private static func entryType(_ url: URL) -> mode_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }

    /// A directory that is no symlink and has none above it, so nothing written or removed in it lands elsewhere.
    private static func isRealDirectory(_ folder: URL) -> Bool {
        entryType(folder) == S_IFDIR
            && folder.resolvingSymlinksInPath().standardizedFileURL.path == folder.standardizedFileURL.path
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let x = try? a.resourceValues(forKeys: keys), let y = try? b.resourceValues(forKeys: keys) else { return false }
        return x.fileSize == y.fileSize && x.contentModificationDate == y.contentModificationDate
    }

    private static func removeIfPresent(_ name: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func removeFiles(_ names: [String], in folder: URL) throws {
        for name in names { try FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }
}
