import AppKit
import Combine

@MainActor
final class VideoLibrary: ObservableObject {
    @Published private(set) var categories: [LibraryCategory] = []
    /// The one "current wallpaper" the menu and the cards read; nil when nothing is playing.
    @Published private(set) var currentPath: String?
    /// Every file the user added that played, including ones on a drive that is not connected right now.
    @Published private(set) var userFiles: [URL] = []
    /// User files the last scan could not find; the gallery dims them and offers only removal.
    @Published private(set) var missingUserFiles: Set<URL> = []
    /// Errors from user actions (drop, open, missing or unplayable file).
    @Published private(set) var errorMessage: LocalizedMessage?
    /// Problems found by the last scan; once dismissed they stay hidden until they change.
    @Published private(set) var scanNotice: [LocalizedMessage] = []

    let settings: AppSettings
    let lockScreen = LockScreenSync()
    private let onApply: (URL) -> Void
    private let defaults = UserDefaults.standard
    private let videoPathKey = "videoPath"
    private let userFilesKey = "userFiles"
    private var defaultItem: LibraryItem?
    private var dismissedScanNotice: [LocalizedMessage] = []
    /// The file the player last confirmed; a failed apply points back at it (it never stopped playing).
    private var lastGoodPath: String?
    /// A new "My Videos" file waiting for its playable check; it joins the list only if it passes.
    private var pendingUserFile: URL?
    /// A variant switch the app made on its own (screens, power); its failure only sets the banner.
    private var automaticPath: String?
    private var isScanning = false
    private var needsRescan = false
    private var scanCompletions: [@MainActor () -> Void] = []
    private var qualitySubscription: AnyCancellable?
    private var lockScreenSubscription: AnyCancellable?

    static let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("Wallpapers", isDirectory: true)

    init(settings: AppSettings, onApply: @escaping (URL) -> Void) {
        self.settings = settings
        self.onApply = onApply
        userFiles = (defaults.stringArray(forKey: userFilesKey) ?? []).map { URL(fileURLWithPath: $0) }
        // A saved wallpaper whose file is gone is not playing, so it is not current either.
        currentPath = defaults.string(forKey: videoPathKey).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        // @Published emits before storing, so use the value the sink receives.
        qualitySubscription = settings.$quality.dropFirst().sink { [weak self] quality in
            self?.reapplyCurrentVariant(quality, isAutomatic: false)
        }
        // Not dropFirst: launching with the setting off clears what an earlier run left in the folder.
        lockScreenSubscription = settings.$lockScreenSync.sink { [weak self] enabled in
            self?.updateLockScreen(enabled: enabled)
        }
        for name in [NSApplication.didChangeScreenParametersNotification, .powerSourceChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self.map { $0.reapplyCurrentVariant($0.settings.quality, isAutomatic: true) } }
            }
        }
    }

    var libraryRoot: URL { URL(fileURLWithPath: settings.libraryPath, isDirectory: true) }
    var allItems: [LibraryItem] { categories.flatMap(\.items) }

    var bannerMessage: String? {
        if let errorMessage { return L10n.text(errorMessage) }
        return scanNotice.isEmpty ? nil : scanNotice.map(L10n.text).joined(separator: "\n")
    }

    func showError(_ key: String, _ args: String...) {
        errorMessage = LocalizedMessage(key: key, args: args)
    }

    // MARK: Scanning

    /// Scans off the main thread (user files' presence too); requests made during a scan queue exactly one
    /// follow-up scan, which runs after this scan's result is shown.
    func rescan(then completion: (@MainActor () -> Void)? = nil) {
        if let completion { scanCompletions.append(completion) }
        guard !isScanning else {
            needsRescan = true
            return
        }
        isScanning = true
        let root = libraryRoot
        let createRoot = settings.libraryPath == AppSettings.defaultLibraryPath
        let bundled = Self.bundledRoot
        let files = userFiles
        Task {
            let (result, missing) = await Task.detached {
                (LibraryScanner.scan(libraryRoot: root, createIfMissing: createRoot, bundledRoot: bundled),
                 Set(files.filter { !FileManager.default.fileExists(atPath: $0.path) }))
            }.value
            isScanning = false
            // Only a result for another folder is stale; queued completions then wait for the follow-up.
            if root == libraryRoot { applyScan(result, missingUserFiles: missing) }
            if needsRescan || root != libraryRoot {
                needsRescan = false
                rescan()
            }
        }
    }

    private func applyScan(_ result: LibraryScanResult, missingUserFiles missing: Set<URL>) {
        categories = result.categories
        defaultItem = result.defaultItem
        missingUserFiles = missing
        let notice = Self.notice(for: result)
        if notice.isEmpty { dismissedScanNotice = [] }
        scanNotice = notice == dismissedScanNotice ? [] : notice
        let completions = scanCompletions
        scanCompletions = []
        completions.forEach { $0() }
    }

    private static func notice(for result: LibraryScanResult) -> [LocalizedMessage] {
        let sidecars = result.warnings.compactMap { if case .badSidecar(let folder) = $0 { folder } else { nil } }
        let folders = result.warnings.compactMap { if case .unreadableFolder(let name) = $0 { name } else { nil } }
        return [
            result.rootError.map { LocalizedMessage(key: "library.error.folder", args: [$0]) },
            sidecars.isEmpty ? nil
                : LocalizedMessage(key: "library.warning.badSidecar", args: [sidecars.joined(separator: ", ")]),
            folders.isEmpty ? nil
                : LocalizedMessage(key: "library.warning.unreadable", args: [folders.joined(separator: ", ")]),
        ].compactMap { $0 }
    }

    func dismissBanner() {
        if errorMessage != nil {
            errorMessage = nil
        } else {
            dismissedScanNotice = scanNotice
            scanNotice = []
        }
    }

    // MARK: Selection

    func isCurrent(_ item: LibraryItem) -> Bool {
        item.hasFile(atPath: currentPath)
    }

    func title(for url: URL) -> String {
        allItems.first { $0.variants.values.contains { $0.path == url.path } }?.title
            ?? url.deletingPathExtension().lastPathComponent
    }

    func select(_ item: LibraryItem) {
        guard let url = preferredURL(item, settings.quality) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError("library.error.missingFile", url.lastPathComponent)
            rescan()
            return
        }
        apply(url)
    }

    /// A "My Videos" card; its file may have gone since the gallery was drawn.
    func selectUserFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError("library.error.missingFile", url.lastPathComponent)
            return
        }
        apply(url)
    }

    /// Applies the sidecar default (library first, then bundled); false when there is none, or when `failed`
    /// (a file that just failed to play) is one of its files, so a broken default is never retried.
    func applyDefault(unless failed: URL? = nil) -> Bool {
        guard let defaultItem, !defaultItem.hasFile(atPath: failed?.path) else { return false }
        select(defaultItem)
        return true
    }

    private func preferredURL(_ item: LibraryItem, _ quality: QualityPreference) -> URL? {
        VariantChooser.choose(quality, available: Set(item.variants.keys),
                              maxPixelWidth: Self.maxScreenPixelWidth(), onBattery: PowerSource.isOnBattery())
            .flatMap { item.variants[$0] }
    }

    private static func maxScreenPixelWidth() -> Double {
        NSScreen.screens.map { Double($0.frame.width * $0.backingScaleFactor) }.max() ?? 0
    }

    private func reapplyCurrentVariant(_ quality: QualityPreference, isAutomatic: Bool) {
        guard let item = allItems.first(where: isCurrent), let url = preferredURL(item, quality),
              url.path != currentPath else { return }
        apply(url, isAutomatic: isAutomatic)
    }

    // MARK: User files and playback results

    /// Joins "My Videos" only once the player confirms it plays (see `playbackReady`).
    func addUserFile(_ url: URL) {
        pendingUserFile = userFiles.contains(url) ? nil : url
        apply(url)
    }

    func removeUserFile(_ url: URL) {
        userFiles = userFiles.filter { $0 != url }
        persistUserFiles()
    }

    private func persistUserFiles() {
        defaults.set(userFiles.map(\.path), forKey: userFilesKey)
    }

    func apply(_ url: URL, isAutomatic: Bool = false) {
        automaticPath = isAutomatic ? url.path : nil
        setCurrent(url.path)
        onApply(url)
    }

    /// The player now shows `url`: later failures go back to it, and a new user file joins the list.
    func playbackReady(_ url: URL) {
        lastGoodPath = url.path
        if url == pendingUserFile {
            userFiles = userFiles + [url]
            persistUserFiles()
        }
        pendingUserFile = nil
        if missingUserFiles.contains(url) { missingUserFiles = missingUserFiles.subtracting([url]) }
        updateLockScreen(enabled: settings.lockScreenSync)
    }

    /// Mirrors the file the player confirmed (the chosen variant) for the Lock Screen extension on macOS 26+,
    /// or clears the folder when the setting is off.
    private func updateLockScreen(enabled: Bool) {
        guard #available(macOS 26, *) else { return }
        guard enabled else {
            lockScreen.clear()
            return
        }
        guard let path = lastGoodPath else { return }
        lockScreen.sync(source: URL(fileURLWithPath: path))
    }

    /// The player could not open `url` and kept showing the last good file: report it and point current (and
    /// the saved path) back at that file, or at nothing. False when the user should not be interrupted:
    /// a stale result, or a variant switch the app made on its own.
    func playbackFailed(_ url: URL) -> Bool {
        pendingUserFile = nil
        guard url.path == currentPath else { return false }
        showError("library.error.cantPlay", url.lastPathComponent)
        setCurrent(lastGoodPath)
        return url.path != automaticPath
    }

    private func setCurrent(_ path: String?) {
        currentPath = path
        defaults.set(path, forKey: videoPathKey)
    }
}
