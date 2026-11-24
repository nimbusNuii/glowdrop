import AppKit
import Combine
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    nonisolated private static let logger = Logger(subsystem: "io.github.nimbusnuii.glowdrop", category: "wallpaper")
    private let settings: AppSettings
    private let controller: WallpaperController
    private lazy var library = VideoLibrary(settings: settings, onApply: { [weak self] url in self?.controller.play(url: url) })
    private lazy var gallery = GalleryWindowController(library: library, settings: settings)
    private lazy var settingsWindow = SettingsWindowController(settings: settings, library: library)
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem()
    private let autoPauseItem = NSMenuItem()
    private let libraryItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let restartAgentItem = NSMenuItem()
    private let settingsItem = NSMenuItem()
    private let quitItem = NSMenuItem()
    private var didFinishLaunching = false
    private var openedFileAtLaunch = false
    /// A glowdrop:// link that arrived before launch finished; handled once it has.
    private var launchLink: GlowdropLink?
    /// An Add Video panel from a link is open or about to open; another add-video link only shows the gallery.
    private var isAddingVideo = false
    /// The saved wallpaper re-applied at launch, until the player has checked it.
    private var launchPath: String?
    private var engineSubscription: AnyCancellable?

    override init() {
        let settings = AppSettings()
        self.settings = settings
        controller = WallpaperController(settings: settings)
        super.init()
        controller.onPlaybackReady = { [weak self] url in
            self?.launchPath = nil
            self?.library.playbackReady(url)
        }
        controller.onPlaybackFailed = { [weak self] url in self?.playbackFailed(url) }
        // Before any file is applied (open events can arrive before launch finishes): the system engine never
        // flashes a window.
        controller.setDesktopWindowsEnabled(!settings.usesSystemEngine)
        // @Published emits before storing, so read the stored engine on the next main-queue turn.
        engineSubscription = settings.$engine.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.engineChanged() }
    }

    /// The window engine draws again from the current file; the system engine leaves the desktop to macOS.
    private func engineChanged() {
        let usesWindow = !settings.usesSystemEngine
        controller.setDesktopWindowsEnabled(usesWindow)
        if usesWindow, let path = library.currentPath { library.apply(URL(fileURLWithPath: path)) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        buildStatusItem()
        NSApp.mainMenu = makeMainMenu()
        // VideoLibrary already dropped a saved path whose file is missing.
        let savedPath = library.currentPath
        // An open event delivered before launch finished already applied its file.
        if !openedFileAtLaunch, let savedPath {
            launchPath = savedPath
            library.apply(URL(fileURLWithPath: savedPath))
        }
        library.rescan { [weak self] in
            guard let self, !self.openedFileAtLaunch, savedPath == nil else { return }
            self.applyDefaultOrShowGallery()
        }
        scheduleExtensionHealthCheck()
        if let link = launchLink {
            launchLink = nil
            handle(link)
        }
    }

    /// The gallery comes forward so its banner explains the failure. A saved wallpaper that no longer plays
    /// at launch gives way to the default once, after a scan has found it.
    private func playbackFailed(_ url: URL) {
        let isLaunchFile = url.path == launchPath
        launchPath = nil
        guard library.playbackFailed(url) else { return }
        if isLaunchFile {
            library.rescan { [weak self] in self?.applyDefaultOrShowGallery(unless: url) }
        } else {
            gallery.show()
        }
    }

    private func applyDefaultOrShowGallery(unless failed: URL? = nil) {
        if !library.applyDefault(unless: failed) { gallery.show() }
    }

    /// The system engine plays on after Glowdrop quits, and nothing would update a covered display's still any more.
    func applicationWillTerminate(_ notification: Notification) {
        library.lockScreen.releaseCoveredDisplays()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        gallery.show()
        return true
    }

    // AppKit delivers document-open events after applicationWillFinishLaunching and before
    // applicationDidFinishLaunching; when the app is already running they arrive any time. glowdrop:// links arrive
    // the same way; any other URL is logged and ignored.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { openFiles(files) }
        // One link per event: both show the gallery, and a burst should not stack Add Video panels.
        guard let link = urls.filter({ !$0.isFileURL }).compactMap(link(from:)).last else { return }
        if didFinishLaunching { handle(link) } else { launchLink = link }
    }

    /// Any app or web page can send a URL here: only the scheme of one that is no link goes to the log in the clear.
    private func link(from url: URL) -> GlowdropLink? {
        if let link = GlowdropLink(url: url) { return link }
        let scheme = url.scheme ?? "schemeless"
        Self.logger.notice("ignored a \(scheme, privacy: .public) URL: \(url.absoluteString, privacy: .private)")
        return nil
    }

    /// The tile menu's links: the gallery comes forward (activating the app), with the Add Video panel for `addVideo`
    /// unless a panel or another modal window is already open.
    private func handle(_ link: GlowdropLink) {
        gallery.show()
        guard link == .addVideo, !isAddingVideo, NSApp.modalWindow == nil else { return }
        isAddingVideo = true
        // Next turn, so the open event returns before the panel runs modally.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.isAddingVideo = false }
                // A modal window (the gallery's own Add Video panel) may have opened meanwhile.
                guard NSApp.modalWindow == nil else { return }
                GalleryActions.addVideo(to: self.library)
            }
        }
    }

    private func openFiles(_ urls: [URL]) {
        let videos = urls.filter { VideoLibrary.isVideoFile($0) }
        guard !videos.isEmpty else {
            let key = urls.lazy.compactMap { VideoLibrary.rejectionKey(for: $0) }.first ?? "gallery.error.notVideo"
            library.showError(key, urls.map(\.lastPathComponent).joined(separator: ", "))
            gallery.show()
            return
        }
        if !didFinishLaunching { openedFileAtLaunch = true }
        for url in videos { library.openFile(url) }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "Glowdrop")
            if let image { button.image = image } else { button.title = "GD" }
        }
        libraryItem.action = #selector(showGallery)
        pauseItem.action = #selector(togglePause)
        restartAgentItem.action = #selector(restartWallpaperAgent)
        settingsItem.action = #selector(showSettings)
        settingsItem.keyEquivalent = ","
        quitItem.action = #selector(quit)
        quitItem.keyEquivalent = "q"
        let menu = NSMenu()
        menu.delegate = self
        let entries = [statusLine, autoPauseItem, .separator(), libraryItem, pauseItem, restartAgentItem, settingsItem,
                       .separator(), quitItem]
        for entry in entries {
            entry.target = entry.action == nil ? nil : self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
    }

    /// Hidden for an accessory app, but it routes ⌘, ⌘W ⌘Q and the Edit shortcuts used by the search field.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.t("menu.settings"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: L10n.t("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: L10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q").target = self
        let editMenu = NSMenu(title: L10n.t("menu.edit"))
        editMenu.addItem(withTitle: L10n.t("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let title = library.currentPath.map { library.title(for: URL(fileURLWithPath: $0)) }
        statusLine.title = title.map { L10n.f("menu.playing", $0) } ?? L10n.t("menu.nothingPlaying")
        let reason = controller.autoPauseReason
        autoPauseItem.isHidden = reason == nil
        autoPauseItem.title = reason.map { L10n.f("menu.autoPaused", L10n.t($0.rawValue)) } ?? ""
        libraryItem.title = L10n.t("menu.library")
        pauseItem.title = L10n.t(controller.isUserPaused ? "menu.resume" : "menu.pause")
        restartAgentItem.isHidden = !usesWallpaperAgent
        restartAgentItem.title = L10n.t("menu.restartAgent")
        settingsItem.title = L10n.t("menu.settings")
        quitItem.title = L10n.t("menu.quit")
    }

    @objc private func showGallery() {
        gallery.show()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func togglePause() {
        let paused = !controller.isUserPaused
        controller.setPaused(paused)
        library.setPaused(paused)
    }

    /// The Wallpaper Agent plays Glowdrop only through the extension (macOS 26+).
    private var usesWallpaperAgent: Bool {
        guard #available(macOS 26, *) else { return false }
        return settings.usesSystemEngine || settings.lockScreenSync
    }

    @objc private func restartWallpaperAgent() {
        DispatchQueue.global(qos: .userInitiated).async { WallpaperAgentHealth.restartAgent(logger: Self.logger) }
    }

    // shortcut: LaunchServices re-registers the ad-hoc-signed app on each launch and stops the extension; drop this when signed/notarized builds no longer re-register.
    private func scheduleExtensionHealthCheck() {
        guard usesWallpaperAgent else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            DispatchQueue.global(qos: .utility).async {
                guard WallpaperAgentHealth.isGlowdropSelected(), !WallpaperAgentHealth.isExtensionRunning() else { return }
                Self.logger.notice("extension stopped after launch; restarting WallpaperAgent")
                WallpaperAgentHealth.restartAgent(logger: Self.logger)
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
