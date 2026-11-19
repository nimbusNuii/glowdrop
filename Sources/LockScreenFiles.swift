import CryptoKit
import Foundation

/// What the app tells the Lock Screen extension: which file in the LockScreen folder to play.
struct LockScreenState: Codable, Equatable, Sendable {
    let file: String
    let updated: Int
}

enum LockScreenFilesError: Error, Equatable {
    /// The source's extension is not one the Lock Screen plays (mp4, mov, m4v).
    case unsupportedType(String)
    /// The LockScreen volume has less than the source's size plus the safety margin free.
    case insufficientSpace(neededBytes: Int64)
}

/// The LockScreen folder contract between the app (writer) and the wallpaper extension (reader).
/// Foundation only: it is compiled into the app, the extension and the selftests.
enum LockScreenFiles {
    static let stateName = "state.json"
    static let maxStateBytes = 4 * 1024
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
        let hex = SHA256.hash(data: Data(path.utf8)).prefix(hashLength / 2).map { String(format: "%02x", $0) }.joined()
        return "\(videoPrefix)\(hex).\(ext)"
    }

    /// True only for names `videoName` makes, so "/", ".." and the user's own files never match.
    static func isVideoName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let stem = parts.first, stem.hasPrefix(videoPrefix) else { return false }
        let hex = stem.dropFirst(videoPrefix.count)
        return hex.count == hashLength && hex.allSatisfy(hexDigits.contains) && videoExtensions.contains(String(parts[1]))
    }

    /// Files the app created that `keep` no longer needs (old videos, interrupted copies); anything else stays.
    static func staleFiles(in names: [String], keeping keep: String?) -> [String] {
        names.filter { name in
            let video = name.hasPrefix(partialPrefix) ? String(name.dropFirst(partialPrefix.count)) : name
            return name != keep && isVideoName(video)
        }
    }

    static func isEnoughSpace(sourceBytes: Int64, availableBytes: Int64) -> Bool {
        availableBytes >= sourceBytes + copyMarginBytes
    }

    // MARK: state.json

    static func encode(_ state: LockScreenState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    /// nil when the data is over 4 KB, is not a state, or names a file the app would never write.
    static func decode(_ data: Data) -> LockScreenState? {
        guard data.count <= maxStateBytes,
              let state = try? JSONDecoder().decode(LockScreenState.self, from: data),
              isVideoName(state.file) else { return nil }
        return state
    }

    /// Opens without following a symlink and without blocking on a FIFO, and reads only a regular file of at most
    /// 4 KB. nil when absent or invalid.
    static func readState(in folder: URL) -> LockScreenState? {
        let fd = open(folder.appendingPathComponent(stateName).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxStateBytes else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return (try? handle.read(upToCount: maxStateBytes + 1)).flatMap(decode)
    }

    /// The state's video, only if it resolves (symlinks included) to a readable regular file directly inside `folder`.
    static func videoURL(for state: LockScreenState, in folder: URL) -> URL? {
        guard isVideoName(state.file) else { return nil }
        let root = folder.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(state.file).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == root.path,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    // MARK: Writing (app side)

    /// Puts `source` (symlinks resolved) in `folder`, points state.json at it, then removes what it replaced.
    /// An instant clone when both are on the same APFS volume, a full copy otherwise.
    static func mirror(_ source: URL, into folder: URL, now: Date = Date()) throws {
        let source = source.resolvingSymlinksInPath()
        guard let name = videoName(forSourcePath: source.path) else {
            throw LockScreenFilesError.unsupportedType(source.pathExtension.lowercased())
        }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copied = try copyIfChanged(source, to: folder.appendingPathComponent(name))
        let stateURL = folder.appendingPathComponent(stateName)
        let previous = copied ? nil : readState(in: folder).flatMap { $0.file == name ? $0 : nil }
        let data = try encode(previous ?? LockScreenState(file: name, updated: Int(now.timeIntervalSince1970)))
        // The same state keeps its `updated`, so the extension does not restart the same video; it is rewritten
        // only when its bytes differ (an older format with extra keys).
        if previous == nil || (try? Data(contentsOf: stateURL)) != data {
            try data.write(to: stateURL, options: .atomic)
        }
        try removeFiles(staleFiles(in: fm.contentsOfDirectory(atPath: folder.path), keeping: name), in: folder)
    }

    /// Removes state.json first (the extension then shows nothing), then every video the app created.
    static func clear(_ folder: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return }
        let state = folder.appendingPathComponent(stateName)
        if fm.fileExists(atPath: state.path) { try fm.removeItem(at: state) }
        try removeFiles(staleFiles(in: fm.contentsOfDirectory(atPath: folder.path), keeping: nil), in: folder)
    }

    /// Copies to a hidden partial file and renames it into place, so a reader never opens half a video.
    /// False when `dest` already holds this file (same size and modification date).
    private static func copyIfChanged(_ source: URL, to dest: URL) throws -> Bool {
        guard !isSameFile(source, dest) else { return false }
        let folder = dest.deletingLastPathComponent()
        let fm = FileManager.default
        let partial = folder.appendingPathComponent(partialPrefix + dest.lastPathComponent)
        // Before the space check, so a crashed multi-GB partial is not counted as used space.
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        // On one volume copyItem clones (APFS) and needs almost no space.
        if !isSameVolume(source, folder) { try requireFreeSpace(for: source, in: folder) }
        do {
            try fm.copyItem(at: source, to: partial)
            guard rename(partial.path, dest.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            // The copy error is the one reported; a partial that survives this is removed by the next mirror or clear.
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

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let x = try? a.resourceValues(forKeys: keys), let y = try? b.resourceValues(forKeys: keys) else { return false }
        return x.fileSize == y.fileSize && x.contentModificationDate == y.contentModificationDate
    }

    private static func removeFiles(_ names: [String], in folder: URL) throws {
        for name in names { try FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }
}
