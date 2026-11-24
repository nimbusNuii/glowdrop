import AppKit
import AVFoundation
import Combine

@MainActor
final class WallpaperController {
    private static let wallpaperLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var windows: [NSWindow] = []
    private var conditions = PlaybackConditions()
    private var rulesSubscription: AnyCancellable?
    private var playGeneration = 0
    /// False while macOS plays the wallpaper (system engine): files are still checked, but never drawn.
    private var desktopWindowsEnabled = true
    /// Called with a file once its playable check passed and it replaced what was playing.
    var onPlaybackReady: (@MainActor (URL) -> Void)?
    /// Called with a file that turned out to be unplayable; whatever played before keeps playing.
    var onPlaybackFailed: (@MainActor (URL) -> Void)?

    var isUserPaused: Bool { conditions.userPaused }
    var autoPauseReason: AutoPauseReason? {
        desktopWindowsEnabled ? PlaybackPolicy.autoPauseReason(conditions) : nil
    }

    init(settings: AppSettings) {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        conditions.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        conditions.onBattery = PowerSource.isOnBattery()
        conditions.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        PowerSource.startMonitoring()
        observeSystem()
        // @Published emits the new values before storing them, so build the rules from what the sink receives.
        let powerRules = Publishers.CombineLatest4(settings.$pauseWhenCovered, settings.$pauseWhenLocked,
                                                   settings.$pauseInLowPowerMode, settings.$pauseOnBattery)
        rulesSubscription = Publishers.CombineLatest(powerRules, settings.$pauseWithReduceMotion)
            .sink { [weak self] rules, reduceMotion in
                let (covered, locked, lowPower, battery) = rules
                self?.setRules(PauseRules(whenCovered: covered, whenLocked: locked, inLowPowerMode: lowPower,
                                          onBattery: battery, withReduceMotion: reduceMotion))
            }
    }

    private func observeSystem() {
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { controller, _ in controller.rebuildWindows() }
        observe(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification) { controller, sender in controller.occlusionChanged(sender) }
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { controller, _ in
            controller.conditions.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            controller.updatePlayback()
        }
        observe(NotificationCenter.default, .powerSourceChanged) { controller, _ in
            controller.conditions.onBattery = PowerSource.isOnBattery()
            controller.updatePlayback()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { controller, _ in controller.setScreensAsleep(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { controller, _ in controller.setScreensAsleep(false) }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { controller, _ in
            controller.conditions.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            controller.updatePlayback()
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { controller, _ in controller.setScreenLocked(true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { controller, _ in controller.setScreenLocked(false) }
    }

    /// Handlers get only the identity of the notification's object: Notification is not Sendable in Swift 6.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (WallpaperController, ObjectIdentifier?) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { if let self { handler(self, sender) } }
        }
    }

    private func setRules(_ rules: PauseRules) {
        conditions.rules = rules
        updatePlayback()
    }

    private func setScreensAsleep(_ value: Bool) {
        conditions.screensAsleep = value
        updatePlayback()
    }

    private func setScreenLocked(_ value: Bool) {
        conditions.screenLocked = value
        updatePlayback()
    }

    private func occlusionChanged(_ sender: ObjectIdentifier?) {
        guard windows.contains(where: { ObjectIdentifier($0) == sender }) else { return }
        refreshVisibility()
    }

    private func refreshVisibility() {
        conditions.desktopVisible = windows.isEmpty || windows.contains { $0.occlusionState.contains(.visible) }
        updatePlayback()
    }

    private func updatePlayback() {
        if PlaybackPolicy.shouldPlay(conditions) { player.play() } else { player.pause() }
    }

    /// Checks the new file first while the current one keeps looping, so a bad file never blanks or restarts it.
    func play(url: URL) {
        playGeneration += 1
        let generation = playGeneration
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey:
                                                       AVAssetReferenceRestrictions.forbidAll.rawValue])
        Task {
            let playable = await Self.hasPlayableVideo(asset)
            // Another file was applied meanwhile; its own check decides.
            guard generation == playGeneration else { return }
            if !playable {
                onPlaybackFailed?(url)
            } else if desktopWindowsEnabled {
                startLooping(asset, url: url)
            } else {
                onPlaybackReady?(url)
            }
        }
    }

    /// The template item's status never leaves `.unknown`, and a looper/item over an undecodable codec
    /// still reports ready, so check that a video track can actually play here.
    private static func hasPlayableVideo(_ asset: AVURLAsset) async -> Bool {
        do {
            for track in try await asset.loadTracks(withMediaType: .video) {
                if try await track.load(.isPlayable) { return true }
            }
            return false
        } catch {
            // Unreadable or not a movie at all (AVFoundation -11829/-11800): reported as unplayable.
            return false
        }
    }

    private func startLooping(_ asset: AVURLAsset, url: URL) {
        stopLooping()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        conditions.hasVideo = true
        if windows.isEmpty { rebuildWindows() } else { updatePlayback() }
        onPlaybackReady?(url)
    }

    private func stopLooping() {
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }

    /// Disabling stops the video and closes the windows (rebuildWindows then pauses the player, as there is no video).
    /// Re-enabling shows nothing until the next `play(url:)`.
    func setDesktopWindowsEnabled(_ enabled: Bool) {
        desktopWindowsEnabled = enabled
        guard !enabled else { return }
        stopLooping()
        conditions.hasVideo = false
        rebuildWindows()
    }

    func setPaused(_ paused: Bool) {
        conditions.userPaused = paused
        updatePlayback()
    }

    /// Closes the windows and builds new ones only when a checked video exists, so no black desktop shows otherwise.
    func rebuildWindows() {
        windows.forEach { $0.close() }
        windows = conditions.hasVideo ? NSScreen.screens.map { makeWindow(for: $0) } : []
        refreshVisibility()
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = Self.wallpaperLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black

        let view = NSView()
        view.wantsLayer = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = view.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(playerLayer)
        window.contentView = view

        window.setFrame(screen.frame, display: true)
        window.orderFront(nil)
        return window
    }
}
