import Combine
import Foundation
import os

/// Copies the video the app is playing into the folder the Lock Screen extension reads (macOS 26+).
/// File work runs in order on a utility queue, so a slow copy never blocks the UI; a failed update keeps
/// the folder's previous state.
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
    /// The source last mirrored, so the same file playing again does no work.
    private var syncedPath: String?

    func sync(source: URL) {
        guard source.path != syncedPath else { return }
        let ext = source.pathExtension.lowercased()
        guard LockScreenFiles.videoExtensions.contains(ext) else {
            Self.logger.notice("Lock Screen skips a .\(ext, privacy: .public) file: it plays only mp4, mov and m4v")
            return
        }
        syncedPath = source.path
        let folder = Self.folder
        run(source.path) { try LockScreenFiles.mirror(source, into: folder) }
    }

    /// Removes state.json and the videos the app created; nothing else in the folder is touched.
    func clear() {
        syncedPath = nil
        let folder = Self.folder
        run(nil) { try LockScreenFiles.clear(folder) }
    }

    private func run(_ path: String?, _ work: @escaping @Sendable () throws -> Void) {
        let latestJob = latestJob
        let job = latestJob.withLock { latest in
            latest += 1
            return latest
        }
        queue.async { [weak self] in
            guard latestJob.withLock({ $0 }) == job else { return }
            let failure: LocalizedMessage?
            do {
                try work()
                failure = nil
            } catch {
                failure = Self.message(for: error)
                Self.logger.error("Lock Screen folder update failed: \(error.localizedDescription, privacy: .private)")
            }
            Task { @MainActor in self?.finish(path, failure: failure) }
        }
    }

    nonisolated private static func message(for error: any Error) -> LocalizedMessage {
        guard case let .insufficientSpace(needed) = error as? LockScreenFilesError else {
            return LocalizedMessage(key: "settings.lockScreen.error", args: [error.localizedDescription])
        }
        return LocalizedMessage(key: "settings.lockScreen.noSpace",
                                args: [ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)])
    }

    private func finish(_ path: String?, failure: LocalizedMessage?) {
        lastError = failure
        // A failed source is retried the next time it plays.
        if failure != nil, path == syncedPath { syncedPath = nil }
    }
}
