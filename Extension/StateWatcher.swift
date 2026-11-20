// Watches the LockScreen folder the app writes and hands each state and catalog to the store.

import Foundation

@MainActor
final class StateWatcher {
    private static let debounce: TimeInterval = 0.5
    /// The folder exists only once the app has mirrored a video; until then it is looked for again.
    private static let retryInterval: TimeInterval = 10

    private let folder: URL
    private let onChange: @MainActor (LockScreenState?, URL?, WallpaperCatalog?) -> Void
    private var source: (any DispatchSourceFileSystemObject)?
    private var pendingReload: DispatchWorkItem?

    init(folder: URL, onChange: @escaping @MainActor (LockScreenState?, URL?, WallpaperCatalog?) -> Void) {
        self.folder = folder
        self.onChange = onChange
    }

    func start() {
        reload()
        watch()
    }

    private func watch() {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
                MainActor.assumeIsolated { self?.watch() }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        wallpaperLog("[State] watching the LockScreen folder")
        scheduleReload()
    }

    private func folderChanged() {
        guard let source else { return }
        if !source.data.isDisjoint(with: [.delete, .rename]) {
            // The folder itself went away: watch for it again.
            source.cancel()
            self.source = nil
            watch()
        }
        scheduleReload()
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        pendingReload = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: item)
    }

    private func reload() {
        let state = LockScreenFiles.readState(in: folder)
        let url = state.flatMap { LockScreenFiles.videoURL(for: $0, in: folder) }
        if let state, url == nil { wallpaperLog("[State] \(state.file) is not a readable file in the folder") }
        onChange(state, url, LockScreenFiles.readCatalog(in: folder))
    }
}
