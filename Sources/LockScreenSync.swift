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
        }

        let current: String
        let flags: PlaybackFlags
        let catalog: [Tile]?
    }

    func sync(current: URL, flags: PlaybackFlags, catalog: [CatalogSource]?) {
        let key = SyncKey(current: current.path, flags: flags,
                          catalog: catalog?.map { SyncKey.Tile(path: $0.source.path, title: $0.title) })
        guard key != syncedKey else { return }
        let ext = current.pathExtension.lowercased()
        guard LockScreenFiles.videoExtensions.contains(ext) else {
            Self.logger.notice("Lock Screen skips a .\(ext, privacy: .public) file: it plays only mp4, mov and m4v")
            return
        }
        syncedKey = key
        let folder = Self.folder
        run(key) { try LockScreenFiles.sync(current: current, flags: flags, catalog: catalog, into: folder) }
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

    private func run(_ key: SyncKey?, _ work: @escaping @Sendable () throws -> SyncReport) {
        let latestJob = latestJob
        let job = latestJob.withLock { latest in
            latest += 1
            return latest
        }
        queue.async { [weak self] in
            guard latestJob.withLock({ $0 }) == job else { return }
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
            Task { @MainActor in self?.finish(key, failure: failure, retry: retry) }
        }
    }

    nonisolated private static func message(for error: any Error) -> LocalizedMessage {
        guard case let .insufficientSpace(needed) = error as? LockScreenFilesError else {
            return LocalizedMessage(key: "settings.shared.error", args: [error.localizedDescription])
        }
        return LocalizedMessage(key: "settings.shared.noSpace",
                                args: [ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)])
    }

    private func finish(_ key: SyncKey?, failure: LocalizedMessage?, retry: Bool) {
        lastError = failure
        // A failed request, or one whose catalog clones failed, is retried the next time it is made.
        if retry, key == syncedKey { syncedKey = nil }
    }
}
