// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.
//
// One remote CAContext + layer tree per WallpaperID (desktop Space, lock-screen surface, Settings
// preview), all showing the video the app mirrored. Main actor: agent XPC calls hop here in arrival
// order, so an invalidate can't interleave with an acquire.

import CoreMedia
import Foundation
import QuartzCore

typealias AcquireReply = @Sendable (Any?, (any Error)?) -> Void

/// The video every surface shows, with its first frame as the still. Made once per video: every surface
/// enqueues the same sample buffer, and snapshots draw the same image.
struct CurrentVideo {
    let url: URL
    let still: CGImage?
    let stillSample: CMSampleBuffer?
}

struct HostedSurface {
    let context: RemoteContext
    let rootLayer: CALayer
    var presentation: SurfacePresentation
    var player: SurfacePlayer?
}

@MainActor
final class SurfaceStore {
    static let shared = SurfaceStore()

    /// What state.json named last, and its validated file (nil: missing, invalid or unreadable).
    private(set) var shownState: LockScreenState?
    private(set) var shownURL: URL?
    private var video: CurrentVideo?
    private var surfaces: [UUID: HostedSurface] = [:]
    private var screen = ScreenState()
    private var watcher: StateWatcher?

    func start() {
        guard watcher == nil else { return }
        SystemEvents.start(self)
        let watcher = StateWatcher(folder: WallpaperPaths.lockScreenDir) { [weak self] state, url in
            self?.show(state, url: url)
        }
        self.watcher = watcher
        watcher.start()
    }

    // MARK: Agent lifecycle

    func acquire(key: UUID, params: AcquireParams, reply: AcquireReply) {
        if surfaces[key] == nil {
            guard let surface = makeSurface(params) else {
                reply(nil, wallpaperError(4, "Failed to create remote CAContext"))
                return
            }
            surfaces[key] = surface
            wallpaperLog("ACQUIRE create ctx=\(surface.context.contextId) surface=\(key) size=\(params.size) "
                + "@\(params.scale)x preview=\(params.isPreview) display=\(params.displayID.map(String.init) ?? "nil")")
        }
        guard let contextId = surfaces[key]?.context.contextId,
              let replyObject = createRemoteContextXPC(contextId: contextId) else {
            reply(nil, wallpaperError(3, "Failed to build WallpaperRemoteContextXPC"))
            return
        }
        reconcile()
        reply(replyObject, nil)
    }

    /// shortcut: tears down at once; Phosphene waits a 15 s grace so a quick re-acquire reuses the
    /// context. Port that if surfaces flash dark on sleep/wake or Space switches.
    func invalidate(key: UUID?) {
        guard let key, let surface = surfaces.removeValue(forKey: key) else {
            wallpaperLog("INVALIDATE unknown surface: ignored")
            return
        }
        surface.player?.stop()
        surface.context.invalidate()
        wallpaperLog("INVALIDATE surface=\(key) torn down (\(surfaces.count) left)")
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
        wallpaperLog("SCREEN locked=\(next.screenLocked) screenSaver=\(next.screenSaverRunning) asleep=\(next.displaysAsleep)")
        reconcile()
    }

    // MARK: Video

    /// Switches every surface to the state's video, or to the neutral dark background when there is none.
    /// The new still is made first, so a surface never goes blank between two videos.
    func show(_ state: LockScreenState?, url: URL?) {
        guard state != shownState || url != shownURL else { return }
        shownState = state
        shownURL = url
        guard let url else {
            replace(with: nil)
            return
        }
        Task {
            let still = await firstFrame(of: url)
            // A newer state arrived while the still was being made.
            guard shownState == state, shownURL == url else { return }
            replace(with: CurrentVideo(url: url, still: still, stillSample: still.flatMap(makeStillSampleBuffer)))
        }
    }

    /// The current still, made now when the video is still loading.
    func stillImage() async -> CGImage? {
        if let video { return video.still }
        guard let shownURL else { return nil }
        return await firstFrame(of: shownURL)
    }

    private func replace(with newVideo: CurrentVideo?) {
        video = newVideo
        wallpaperLog("VIDEO \(newVideo?.url.lastPathComponent ?? "none") still=\(newVideo?.still != nil)")
        for key in surfaces.keys {
            guard let surface = surfaces[key] else { continue }
            surfaces[key]?.player = newVideo.flatMap {
                SurfacePlayer(url: $0.url, stillSample: $0.stillSample, rootLayer: surface.rootLayer)
            }
            surface.player?.stop()
        }
        reconcile()
    }

    private func reconcile() {
        for surface in surfaces.values {
            surface.player?.setDecoding(LockScreenPlayback.shouldDecode(surface.presentation, screen))
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
        let player = video.flatMap { SurfacePlayer(url: $0.url, stillSample: $0.stillSample, rootLayer: root) }
        return HostedSurface(context: context, rootLayer: root,
                             presentation: SurfacePresentation(isPreview: params.isPreview), player: player)
    }
}
