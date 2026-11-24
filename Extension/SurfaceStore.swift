// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.
//
// One remote CAContext + layer tree per WallpaperID (desktop Space, lock-screen surface, Settings
// preview), each showing the video its tile picks: one catalog video, or whatever the app plays. Main
// actor: agent XPC calls hop here in arrival order, so an invalidate can't interleave with an acquire.

import CoreMedia
import Foundation
import QuartzCore

typealias AcquireReply = @Sendable (Any?, (any Error)?) -> Void

/// A video with its first frame as the still. Made once per video: every surface showing it enqueues the
/// same sample buffer, and snapshots draw the same image.
struct CurrentVideo {
    let url: URL
    let still: CGImage?
    let stillSample: CMSampleBuffer?
}

struct HostedSurface {
    let context: RemoteContext
    let rootLayer: CALayer
    var presentation: SurfacePresentation
    var choice: WallpaperChoice
    var size: CGSize
    var scale: CGFloat
    /// The video `player` shows, as its still is keyed (a catalog video's main file, even while the player reads its
    /// battery clone); nil without a player, or once the file was replaced under it. A switch at the loop changes it
    /// when the player swaps, not when it is asked to.
    var videoURL: URL?
    var player: SurfacePlayer?
    /// The tile `player` last played for: only Shuffle's own players wait for their loop to take its next video.
    var playerChoice: WallpaperChoice?
}

@MainActor
final class SurfaceStore {
    static let shared = SurfaceStore()
    /// A re-acquire within this time reuses an invalidated surface's context, as in Phosphene.
    private static let teardownGrace: TimeInterval = 15

    /// What state.json named last, and its validated file (nil: missing, invalid or unreadable).
    private(set) var shownState: LockScreenState?
    private(set) var shownURL: URL?
    /// What catalog.json listed last (nil: missing or invalid).
    private(set) var catalog: WallpaperCatalog?
    private var videos: [URL: CurrentVideo] = [:]
    /// Stills being made, each with a token so the still of a replaced file is dropped.
    private var stillLoads: [URL: UUID] = [:]
    private var surfaces: [UUID: HostedSurface] = [:]
    private var teardowns: [UUID: DispatchWorkItem] = [:]
    private var screen = ScreenState()
    private var watcher: StateWatcher?
    /// Wakes the store at Shuffle's next slot boundary while any surface shows Shuffle.
    private var shuffleTimer: DispatchWorkItem?

    func start() {
        guard watcher == nil else { return }
        SystemEvents.start(self)
        let watcher = StateWatcher(folder: WallpaperPaths.lockScreenDir) { [weak self] state, url, catalog in
            self?.show(state: state, url: url, catalog: catalog)
        }
        self.watcher = watcher
        watcher.start()
    }

    // MARK: Agent lifecycle

    func acquire(key: UUID, params: AcquireParams, reply: AcquireReply) {
        cancelTeardown(key)
        if surfaces[key] != nil {
            reacquire(key, params)
        } else {
            guard let surface = makeSurface(params) else {
                reply(nil, wallpaperError(4, "Failed to create remote CAContext"))
                return
            }
            surfaces[key] = surface
            wallpaperLog("ACQUIRE create ctx=\(surface.context.contextId) surface=\(key) size=\(params.size) "
                + "@\(params.scale)x preview=\(params.isPreview) display=\(params.displayID.map(String.init) ?? "nil") "
                + "choice=\(surface.choice)")
        }
        guard let contextId = surfaces[key]?.context.contextId,
              let replyObject = createRemoteContextXPC(contextId: contextId) else {
            reply(nil, wallpaperError(3, "Failed to build WallpaperRemoteContextXPC"))
            return
        }
        resolveSurfaces()
        reply(replyObject, nil)
    }

    /// The same WallpaperID again (wake, Space switch, a new pick): the context stays, geometry and choice follow.
    private func reacquire(_ key: UUID, _ params: AcquireParams) {
        guard var surface = surfaces[key] else { return }
        if surface.size != params.size || surface.scale != params.scale {
            surface.size = params.size
            surface.scale = params.scale
            let root = surface.rootLayer
            withoutAnimation {
                root.frame = CGRect(origin: .zero, size: params.size)
                root.contentsScale = params.scale
            }
            surface.player?.resize(to: root.bounds, scale: params.scale)
        }
        // An acquire without a configuration keeps the tile picked earlier.
        if let choice = params.choice { surface.choice = WallpaperChoice(configuration: choice) }
        if let displayID = params.displayID { surface.presentation.displayID = displayID }
        surface.presentation.activity = .active
        surfaces[key] = surface
        wallpaperLog("ACQUIRE reuse ctx=\(surface.context.contextId) surface=\(key) size=\(params.size) "
            + "@\(params.scale)x choice=\(surface.choice)")
    }

    /// A preview goes at once; any other surface after a grace, so a quick re-acquire (wake, Space switch, a new
    /// pick) reuses its context instead of flashing dark. Suspended meanwhile, so it stops decoding.
    func invalidate(key: UUID?) {
        guard let key, let surface = surfaces[key] else {
            wallpaperLog("INVALIDATE unknown surface: ignored")
            return
        }
        guard !surface.presentation.isPreview else {
            tearDown(key)
            return
        }
        surfaces[key]?.presentation.activity = .suspended
        reconcile()
        teardowns[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tearDown(key) }
        }
        teardowns[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.teardownGrace, execute: item)
        wallpaperLog("INVALIDATE surface=\(key) teardown in \(Int(Self.teardownGrace)) s")
    }

    private func cancelTeardown(_ key: UUID) {
        guard let item = teardowns.removeValue(forKey: key) else { return }
        item.cancel()
        wallpaperLog("TEARDOWN cancelled surface=\(key) (re-acquired)")
    }

    private func tearDown(_ key: UUID) {
        teardowns[key] = nil
        guard let surface = surfaces.removeValue(forKey: key) else { return }
        surface.player?.stop()
        surface.context.invalidate()
        wallpaperLog("TEARDOWN surface=\(key) (\(surfaces.count) left)")
        resolveSurfaces()
    }

    /// An update whose WallpaperID is not one of ours applies to every surface, as in Phosphene.
    func update(key: UUID?, mode: PresentationMode, activity: ActivityState) {
        let keys = key.flatMap { surfaces[$0] == nil ? nil : [$0] } ?? Array(surfaces.keys)
        for key in keys {
            surfaces[key]?.presentation.mode = mode
            surfaces[key]?.presentation.activity = activity
        }
        wallpaperLog("UPDATE \(key.map(\.uuidString) ?? "all") mode=\(mode) activity=\(activity)")
        reconcile()
    }

    /// Power and heat also pick the clone each catalog video plays, so the surfaces are resolved again.
    func updateScreen(_ change: (inout ScreenState) -> Void) {
        var next = screen
        change(&next)
        guard next != screen else { return }
        screen = next
        wallpaperLog("SCREEN locked=\(next.screenLocked) screenSaver=\(next.screenSaverRunning) asleep=\(next.displaysAsleep) "
            + "lowPower=\(next.lowPowerMode) battery=\(next.onBattery) warm=\(next.thermalElevated) "
            + "hot=\(next.thermalHigh) reduceMotion=\(next.reduceMotion)")
        resolveSurfaces()
    }

    // MARK: Video

    /// What StateWatcher read. A new app video or catalog re-points the surfaces it affects; a flags-only change
    /// re-applies the decode policy and never restarts a video, though a new Shuffle interval re-resolves Shuffle's
    /// surfaces. A catalog video copied again gets a new still and player, and the agent fetches its stills again.
    func show(state: LockScreenState?, url: URL?, catalog: WallpaperCatalog?) {
        let change = LockScreenPlayback.change(from: shownState, oldURL: shownURL, oldCatalog: self.catalog,
                                               to: state, url: url, catalog: catalog)
        let intervalChanged = state?.flags.shuffleInterval != shownState?.flags.shuffleInterval
        if change.refreshFollowVideo, let url { dropVideo(url) }
        for file in change.refreshedCatalogFiles {
            if let url = LockScreenFiles.videoURL(named: file, in: WallpaperPaths.lockScreenDir) { dropVideo(url) }
        }
        let covered = state?.flags.coveredDisplays ?? []
        if covered != (shownState?.flags.coveredDisplays ?? []) { wallpaperLog("COVERED \(covered)") }
        shownState = state
        shownURL = url
        self.catalog = catalog
        if change.catalogChanged { SettingsPush.catalogDidChange() }
        if !change.refreshedCatalogFiles.isEmpty { SettingsPush.invalidateSnapshots() }
        guard change.followChanged || change.catalogChanged || intervalChanged else {
            reconcile()
            return
        }
        wallpaperLog("STATE follow=\(state?.file ?? "none") catalog=\(catalog?.items.count ?? 0) items "
            + "shuffle=\(Int(shuffleInterval)) s")
        resolveSurfaces()
    }

    /// The still of the video `key`'s surface shows: its player's (until a switch at the loop swaps it), else the one
    /// its choice resolves to, else the app's video; made now when it is still loading.
    func stillImage(for key: UUID?) async -> CGImage? {
        let surface = key.flatMap { surfaces[$0] }
        let url = surface?.videoURL ?? surface.flatMap { resolved(for: $0.choice)?.video } ?? shownURL
        guard let url else { return nil }
        if let video = videos[url] { return video.still }
        return await firstFrame(of: url)
    }

    /// Points every surface at the video its choice resolves to, in the clone the screen state picks. A surface whose
    /// next video has no still yet keeps its current player until the still is made, so it never goes blank between
    /// two videos.
    private func resolveSurfaces() {
        let wanted = surfaces.mapValues { resolved(for: $0.choice) }
        var replacedVideo = false
        for (key, urls) in wanted { replacedVideo = attach(urls, to: key) || replacedVideo }
        let used = Set(wanted.values.compactMap { $0?.video })
        videos = videos.filter { used.contains($0.key) }
        for url in used where videos[url] == nil { makeStill(for: url) }
        reconcile()
        armShuffleTimer()
        // A surface shows another video now, so the agent fetches the stills again.
        if replacedVideo { SettingsPush.invalidateSnapshots() }
    }

    /// A catalog video while the catalog lists it and its file is readable; otherwise the app's video. Stills are keyed
    /// to `video`; `play` is the clone `LockScreenPlayback.variantFile` picks when it is readable, else `video`.
    private func resolved(for choice: WallpaperChoice) -> (video: URL, play: URL)? {
        let folder = WallpaperPaths.lockScreenDir
        guard let item = catalogItem(for: choice),
              let url = LockScreenFiles.videoURL(named: item.file, in: folder) else {
            return shownURL.map { (video: $0, play: $0) }
        }
        let variant = LockScreenPlayback.variantFile(of: item, screen)
        return (url, variant == item.file ? url : LockScreenFiles.videoURL(named: variant, in: folder) ?? url)
    }

    /// The catalog video a tile picks: its own, or the one Shuffle's schedule picks now; nil for the follow tile.
    private func catalogItem(for choice: WallpaperChoice) -> WallpaperCatalog.Item? {
        let items = catalog?.items ?? []
        switch choice {
        case .follow:
            return nil
        case let .video(file):
            return items.first { $0.file == file }
        case .shuffle:
            let index = LockScreenPlayback.shuffleIndex(at: Date(), interval: shuffleInterval, count: items.count)
            return index.map { items[$0] }
        }
    }

    /// Seconds between Shuffle's videos, as the app's settings say.
    private var shuffleInterval: TimeInterval {
        TimeInterval((shownState?.flags ?? PlaybackFlags()).shuffleInterval)
    }

    /// No URL: the neutral dark background. A player that takes the resolved file at its next loop (see
    /// `switchesAtLoop`) keeps playing until then; otherwise it is replaced, once the new video's still is made (until
    /// then nothing changes). True when a player that showed one video was replaced by one showing another.
    private func attach(_ urls: (video: URL, play: URL)?, to key: UUID) -> Bool {
        guard let surface = surfaces[key] else { return false }
        guard let urls else {
            surface.player?.stop()
            surfaces[key]?.player = nil
            surfaces[key]?.videoURL = nil
            return false
        }
        if let player = surface.player, switchesAtLoop(surface, player, to: urls.video) {
            let video = urls.video
            player.switchAtLoop(to: urls.play, didSwitch: { [weak self] in
                // A file replaced meanwhile stays marked, so its player is still replaced.
                guard let self, let shown = surfaces[key]?.videoURL else { return }
                surfaces[key]?.videoURL = video
                if shown != video { SettingsPush.invalidateSnapshots() }
            }, didFail: { [weak self] in self?.switchFailed(key) })
            surfaces[key]?.playerChoice = surface.choice
            return false
        }
        guard let video = videos[urls.video] else { return false }
        // The new layer goes above the old one, which leaves only once the new still is in place.
        let player = SurfacePlayer(url: urls.play, stillSample: video.stillSample, rootLayer: surface.rootLayer)
        surface.player?.stop()
        surfaces[key]?.player = player
        surfaces[key]?.videoURL = urls.video
        surfaces[key]?.playerChoice = surface.choice
        wallpaperLog("SHOW surface=\(key) \(urls.play.lastPathComponent)")
        return surface.videoURL.map { $0 != urls.video } ?? false
    }

    /// A player switched to a file it can't read: it no longer counts as showing that video, so it is replaced.
    private func switchFailed(_ key: UUID) {
        surfaces[key]?.videoURL = nil
        // Next turn: the player calls this from inside its own read, which a resolve may reach again.
        Task { [weak self] in self?.resolveSurfaces() }
    }

    /// The same video: its player, decoding or held, takes another clone at its next loop (the file playing now cancels
    /// a pending switch), unless the file it is on left the catalog or became unreadable (`LockScreenPlayback
    /// .switchesAtLoop`). Another video: only a Shuffle player that is decoding waits for its loop, while the video it
    /// shows is still listed (`LockScreenPlayback.shuffleSwitchesAtLoop`).
    private func switchesAtLoop(_ surface: HostedSurface, _ player: SurfacePlayer, to video: URL) -> Bool {
        let current = player.url.lastPathComponent
        let readable = LockScreenFiles.videoURL(named: current, in: WallpaperPaths.lockScreenDir) != nil
        guard surface.videoURL == video else {
            let running = surface.choice == .shuffle && surface.playerChoice == .shuffle && player.wantsDecoding
            return LockScreenPlayback.shuffleSwitchesAtLoop(
                running: running, showing: surface.videoURL?.lastPathComponent, playing: current, catalog: catalog,
                currentReadable: readable)
        }
        return LockScreenPlayback.switchesAtLoop(sameVideo: true, playing: current, video: video.lastPathComponent,
                                                 catalog: catalog, currentReadable: readable)
    }

    /// While any surface shows Shuffle, one wake-up at the next slot boundary resolves the surfaces again, which arms
    /// the next one. A wall-clock deadline, so time asleep counts.
    private func armShuffleTimer() {
        shuffleTimer?.cancel()
        shuffleTimer = nil
        guard surfaces.values.contains(where: { $0.choice == .shuffle }),
              let next = LockScreenPlayback.nextChange(after: Date(), interval: shuffleInterval) else { return }
        // Snapshots follow each player as it takes the next video (`attach`), not the boundary itself.
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                wallpaperLog("SHUFFLE slot boundary")
                self?.resolveSurfaces()
            }
        }
        shuffleTimer = item
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, next.timeIntervalSinceNow), execute: item)
    }

    /// Makes `url`'s still off the main thread, then shows it on every surface that still wants it.
    private func makeStill(for url: URL) {
        guard stillLoads[url] == nil else { return }
        let token = UUID()
        stillLoads[url] = token
        Task {
            let still = await firstFrame(of: url)
            // The file was replaced meanwhile, or no surface wants it any more.
            guard stillLoads[url] == token else { return }
            stillLoads[url] = nil
            guard surfaces.values.contains(where: { resolved(for: $0.choice)?.video == url }) else { return }
            videos[url] = CurrentVideo(url: url, still: still, stillSample: still.flatMap(makeStillSampleBuffer))
            wallpaperLog("VIDEO \(url.lastPathComponent) still=\(still != nil)")
            resolveSurfaces()
        }
    }

    /// Forgets a replaced file's still and marks its players stale; they are swapped once the new still is made. A
    /// switch still waiting to play it is dropped, so the next resolve asks for the new copy.
    private func dropVideo(_ url: URL) {
        videos[url] = nil
        stillLoads[url] = nil
        for key in surfaces.keys where surfaces[key]?.videoURL == url {
            surfaces[key]?.videoURL = nil
        }
        for surface in surfaces.values { surface.player?.cancelPendingSwitch(to: url) }
    }

    private func reconcile() {
        let flags = shownState?.flags ?? PlaybackFlags()
        for surface in surfaces.values {
            surface.player?.setDecoding(LockScreenPlayback.shouldDecode(surface.presentation, screen, flags))
        }
    }

    // MARK: Surfaces

    private func makeSurface(_ params: AcquireParams) -> HostedSurface? {
        guard let context = RemoteContext(displayID: params.displayID) else { return nil }
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: params.size)
        root.contentsScale = params.scale
        root.backgroundColor = neutralDark // shows whenever there is no video
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        context.host(root)
        CATransaction.commit()
        CATransaction.flush()
        return HostedSurface(context: context, rootLayer: root,
                             presentation: SurfacePresentation(isPreview: params.isPreview, displayID: params.displayID),
                             choice: WallpaperChoice(configuration: params.choice), size: params.size, scale: params.scale)
    }
}
