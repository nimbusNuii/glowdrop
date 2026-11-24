import Combine
import Foundation
import os

/// Copies the video the app is playing (and, for the system engine, every gallery video) into the folder the
/// wallpaper extension reads (macOS 26+). File work runs in order on a utility queue, so a slow copy never blocks
/// the UI; a failed update keeps the folder's previous state.
@MainActor
final class LockScreenSync: ObservableObject {
    /// The last update's error, shown in Settings; nil once an update succeeds.
    @Published private(set) var lastError: LocalizedMessage?

    nonisolated private static let logger = Logger(subsystem: "io.github.nimbusnuii.glowdrop", category: "lockscreen")
    private static let folder = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Glowdrop/LockScreen", isDirectory: true)
    private let queue = DispatchQueue(label: "io.github.nimbusnuii.glowdrop.lockscreen", qos: .utility)
    /// Bumped by every queued job; a job that is no longer the latest is skipped, so a superseded copy never runs.
    private let latestJob = OSAllocatedUnfairLock(initialState: 0)
    /// The request last written, so an identical one does no work.
    private var syncedKey: SyncKey?

    private struct SyncKey: Equatable, Sendable {
        struct Tile: Equatable, Sendable {
            let path: String
            let title: String
            let batteryPath: String?
        }

        let current: String
        let flags: PlaybackFlags
        let catalog: [Tile]?

        /// The same video and tiles: only the flags can differ.
        func hasSameFiles(as other: SyncKey) -> Bool {
            current == other.current && catalog == other.catalog
        }
    }

    func sync(current: URL, flags: PlaybackFlags, catalog: [CatalogSource]?) {
        let key = SyncKey(current: current.path, flags: flags,
                          catalog: catalog?.map { SyncKey.Tile(path: $0.source.path, title: $0.title,
                                                               batteryPath: $0.batterySource?.path) })
        guard key != syncedKey else { return }
        let ext = current.pathExtension.lowercased()
        guard LockScreenFiles.videoExtensions.contains(ext) else {
            Self.logger.notice("Lock Screen skips a .\(ext, privacy: .public) file: it plays only mp4, mov and m4v")
            return
        }
        if syncedKey?.hasSameFiles(as: key) == true {
            writeFlags(key)
            return
        }
        syncedKey = key
        let folder = Self.folder
        run(key) { try LockScreenFiles.sync(current: current, flags: flags, catalog: catalog, into: folder) }
    }

    /// Only the flags changed since the last request: state.json alone is rewritten, so the caller need not list the
    /// catalog again. False when there is no request to build on (none yet, or it failed); the caller then syncs.
    func syncFlags(_ flags: PlaybackFlags) -> Bool {
        guard let syncedKey else { return false }
        let key = SyncKey(current: syncedKey.current, flags: flags, catalog: syncedKey.catalog)
        if key != syncedKey { writeFlags(key) }
        return true
    }

    /// The folder's clones are not looked at again; they are checked on the next request that changes a file or tile.
    private func writeFlags(_ key: SyncKey) {
        syncedKey = key
        let flags = key.flags
        let folder = Self.folder
        run(key, flagsOnly: true) {
            try LockScreenFiles.updateFlags(in: folder) { _ in flags }
            return SyncReport(failedCatalogItems: 0)
        }
    }

    /// At quit, on the main thread: empties state.json's covered displays, so a display covered now plays again under
    /// the system engine with Glowdrop gone; the file, `updated` and the other flags stay. Queued full jobs are skipped,
    /// and this runs on the serial queue after the job in flight, so no older list can land over it.
    /// shortcut: quitting waits for a copy in flight (a full copy only for a current video on another volume); make
    /// the copy cancellable if a slow quit is ever reported.
    func releaseCoveredDisplays() {
        latestJob.withLock { $0 += 1 }
        let folder = Self.folder
        queue.sync {
            do {
                try LockScreenFiles.updateFlags(in: folder) { $0.uncovered }
            } catch {
                Self.logger.error("Lock Screen covered displays not released: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Removes state.json, catalog.json and the videos the app created; nothing else in the folder is touched.
    func clear() {
        syncedKey = nil
        let folder = Self.folder
        run(nil) {
            try LockScreenFiles.clear(folder)
            return SyncReport(failedCatalogItems: 0)
        }
    }

    /// A flags-only job neither skips the full job queued before it, which must still write the state it rewrites, nor
    /// is skipped: it only rewrites the flags of whatever state.json holds, and a later full job writes its own.
    private func run(_ key: SyncKey?, flagsOnly: Bool = false, _ work: @escaping @Sendable () throws -> SyncReport) {
        let latestJob = latestJob
        let job: Int? = flagsOnly ? nil : latestJob.withLock { latest in
            latest += 1
            return latest
        }
        queue.async { [weak self] in
            if let job, latestJob.withLock({ $0 }) != job { return }
            let failure: LocalizedMessage?
            let retry: Bool
            do {
                let failed = try work().failedCatalogItems
                if failed > 0 {
                    Self.logger.error("Lock Screen catalog: \(failed, privacy: .public) video(s) could not be cloned")
                }
                failure = nil
                retry = failed > 0
            } catch {
                failure = Self.message(for: error)
                retry = true
                Self.logger.error("Lock Screen folder update failed: \(error.localizedDescription, privacy: .private)")
            }
            Task { @MainActor in self?.finish(key, failure: failure, retry: retry, flagsOnly: flagsOnly) }
        }
    }

    nonisolated private static func message(for error: any Error) -> LocalizedMessage {
        guard case let .insufficientSpace(needed) = error as? LockScreenFilesError else {
            return LocalizedMessage(key: "settings.shared.error", args: [error.localizedDescription])
        }
        return LocalizedMessage(key: "settings.shared.noSpace",
                                args: [ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)])
    }

    private func finish(_ key: SyncKey?, failure: LocalizedMessage?, retry: Bool, flagsOnly: Bool) {
        // A flags-only write says nothing about the clones, so its success keeps a full job's error.
        if failure != nil || !flagsOnly { lastError = failure }
        // A failed request, or one whose catalog clones failed, is retried the next time it is made; a flags-only
        // request made on top of it since then counts as the same request.
        if retry, let key, syncedKey?.hasSameFiles(as: key) == true { syncedKey = nil }
    }
}
