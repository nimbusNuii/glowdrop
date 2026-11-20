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
    /// The video `player` shows; nil without a player, or once the file was replaced under it.
    var videoURL: URL?
    var player: SurfacePlayer?
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

    func updateScreen(_ change: (inout ScreenState) -> Void) {
        var next = screen
        change(&next)
        guard next != screen else { return }
        screen = next
        wallpaperLog("SCREEN locked=\(next.screenLocked) screenSaver=\(next.screenSaverRunning) asleep=\(next.displaysAsleep) "
            + "lowPower=\(next.lowPowerMode) battery=\(next.onBattery) hot=\(next.thermalHigh)")
        reconcile()
    }

    // MARK: Video

    /// What StateWatcher read. A new app video or catalog re-points the surfaces it affects; a flags-only change
    /// re-applies the decode policy and never restarts a video.
    func show(state: LockScreenState?, url: URL?, catalog: WallpaperCatalog?) {
        let change = LockScreenPlayback.change(from: shownState, oldURL: shownURL, oldCatalog: self.catalog,
                                               to: state, url: url, catalog: catalog)
        if change.refreshFollowVideo, let url { dropVideo(url) }
        shownState = state
        shownURL = url
        self.catalog = catalog
        if change.catalogChanged { SettingsPush.catalogDidChange() }
        guard change.followChanged || change.catalogChanged else {
            reconcile()
            return
        }
        wallpaperLog("STATE follow=\(state?.file ?? "none") catalog=\(catalog?.items.count ?? 0) items")
        resolveSurfaces()
    }

    /// The still of `key`'s video, else of the app's video; made now when it is still loading.
    func stillImage(for key: UUID?) async -> CGImage? {
        let url = key.flatMap { surfaces[$0] }.flatMap { resolvedURL(for: $0.choice) } ?? shownURL
        guard let url else { return nil }
        if let video = videos[url] { return video.still }
        return await firstFrame(of: url)
    }

    /// Points every surface at the video its choice resolves to. A surface whose next video has no still yet keeps
    /// its current player until the still is made, so it never goes blank between two videos.
    private func resolveSurfaces() {
        let wanted = surfaces.mapValues { resolvedURL(for: $0.choice) }
        for (key, url) in wanted { attach(url, to: key) }
        let used = Set(wanted.values.compactMap { $0 })
        videos = videos.filter { used.contains($0.key) }
        for url in used where videos[url] == nil { makeStill(for: url) }
        reconcile()
    }

    /// A catalog video while the catalog lists it and its file is readable; otherwise the app's video.
    private func resolvedURL(for choice: WallpaperChoice) -> URL? {
        guard case let .video(file) = choice, catalog?.items.contains(where: { $0.file == file }) == true,
              let url = LockScreenFiles.videoURL(named: file, in: WallpaperPaths.lockScreenDir) else { return shownURL }
        return url
    }

    /// No URL: the neutral dark background. A URL whose still is not made yet: nothing changes for now.
    private func attach(_ url: URL?, to key: UUID) {
        guard let surface = surfaces[key] else { return }
        guard let url else {
            surface.player?.stop()
            surfaces[key]?.player = nil
            surfaces[key]?.videoURL = nil
            return
        }
        guard surface.videoURL != url, let video = videos[url] else { return }
        // The new layer goes above the old one, which leaves only once the new still is in place.
        let player = SurfacePlayer(url: url, stillSample: video.stillSample, rootLayer: surface.rootLayer)
        surface.player?.stop()
        surfaces[key]?.player = player
        surfaces[key]?.videoURL = url
        wallpaperLog("SHOW surface=\(key) \(url.lastPathComponent)")
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
            guard surfaces.values.contains(where: { resolvedURL(for: $0.choice) == url }) else { return }
            videos[url] = CurrentVideo(url: url, still: still, stillSample: still.flatMap(makeStillSampleBuffer))
            wallpaperLog("VIDEO \(url.lastPathComponent) still=\(still != nil)")
            resolveSurfaces()
        }
    }

    /// Forgets a replaced file's still and marks its players stale; they are swapped once the new still is made.
    private func dropVideo(_ url: URL) {
        videos[url] = nil
        stillLoads[url] = nil
        for key in surfaces.keys where surfaces[key]?.videoURL == url {
            surfaces[key]?.videoURL = nil
        }
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
                             presentation: SurfacePresentation(isPreview: params.isPreview),
                             choice: WallpaperChoice(configuration: params.choice), size: params.size, scale: params.scale)
    }
}
