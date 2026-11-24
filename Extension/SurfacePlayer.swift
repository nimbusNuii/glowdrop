// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.
//
// One surface's video. AVPlayerLayer silently fails in a remote CAContext, so this drives
// AVSampleBufferDisplayLayer by hand: AVAssetReader -> enqueue, and at the end of the file a fresh
// reader with a growing PTS offset so the timeline stays monotonic. Main actor: the SDK isolates
// AVSampleBufferDisplayLayer there, and one thread for every layer and renderer call keeps the
// explicit, flushed transactions a remote context needs in order.

import AVFoundation
import CoreMedia
import ObjectiveC

/// Private BOOL setter Apple's WallpaperExtensionKit calls on every AVSBDL; stops the layer painting
/// opaque black before its first frame. No-op if it disappears.
private func setDisallowsVideoLayerDisplayCompositing(_ layer: CALayer, _ flag: Bool) {
    let sel = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: sel), let imp = class_getMethodImplementation(type(of: layer), sel) else { return }
    typealias SetBoolFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(imp, to: SetBoolFn.self)(layer, sel, ObjCBool(flag))
}

func withoutAnimation(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    changes()
    CATransaction.commit()
    CATransaction.flush() // a remote context only sees the tree after flush()
}

private func makeAsset(_ url: URL) -> AVURLAsset {
    AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
}

/// The codec of the asset's video track (its first format description's media subtype); nil, logged, when it can't
/// be read. From the asset, which is Sendable, rather than the track, which is not.
private func videoCodec(of asset: AVURLAsset) async -> FourCharCode? {
    do {
        let track = try await asset.loadTracks(withMediaType: .video).first
        return try await track?.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
    } catch {
        wallpaperLog("[Video] reading the codec failed:", privateDetail: error.localizedDescription)
        return nil
    }
}

@MainActor
final class SurfacePlayer {
    /// Another file, played from the next loop on; `track` is nil while it loads.
    private struct PendingSwitch {
        let url: URL
        let asset: AVURLAsset
        var track: AVAssetTrack?
        var codec: FourCharCode?
        /// Called once the player reads `url`.
        let didSwitch: () -> Void
        /// Called when, after `didSwitch`, no reader opens `url`: the player would hold its last frame for good.
        let didFail: () -> Void
    }

    private(set) var url: URL
    private let layer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private var asset: AVURLAsset
    private var track: AVAssetTrack?
    private var codec: FourCharCode?
    private var isLoadingTrack = false
    private var pendingSwitch: PendingSwitch?
    /// The `didFail` of the switch swapped in at the last seam, until a reader opens its file.
    private var unreadSwitchFailure: (() -> Void)?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// A pause's flush is in flight; reading starts again only after it, never alongside it.
    private var isFlushing = false
    private(set) var wantsDecoding = false
    private var isStopped = false
    private var ptsOffset = CMTime.zero
    private var lastEnqueuedEnd = CMTime.zero

    /// Installs the layer above the root's dark background, showing `stillSample` (shared by every surface)
    /// until decoding starts.
    init?(url: URL, stillSample: CMSampleBuffer?, rootLayer: CALayer) {
        var timebaseOut: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                              timebaseOut: &timebaseOut) == noErr,
              let timebaseOut else { return nil }
        let layer = AVSampleBufferDisplayLayer()
        self.url = url
        self.layer = layer
        renderer = layer.sampleBufferRenderer
        timebase = timebaseOut
        asset = makeAsset(url)
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0)
        layer.controlTimebase = timebase
        layer.videoGravity = .resizeAspectFill
        layer.frame = rootLayer.bounds
        layer.contentsScale = rootLayer.contentsScale
        layer.isOpaque = true
        setDisallowsVideoLayerDisplayCompositing(layer, true)
        withoutAnimation {
            rootLayer.addSublayer(layer)
            if let stillSample { renderer.enqueue(stillSample) }
        }
    }

    /// Decodes while `on`; otherwise the layer holds its frame (the still, or the last decoded one).
    func setDecoding(_ on: Bool) {
        guard on != wantsDecoding, !isStopped else { return }
        wantsDecoding = on
        if on { startReading() } else { pause() }
    }

    /// Follows the surface's new geometry (another display, or a resolution change).
    func resize(to bounds: CGRect, scale: CGFloat) {
        withoutAnimation {
            layer.frame = bounds
            layer.contentsScale = scale
        }
    }

    /// Plays `newURL` (another clone of this video, or Shuffle's next video) from the next loop on, so the change never
    /// cuts the picture: its asset, video track and codec load now, and the seam swaps them in once ready, then calls
    /// `didSwitch`. The file playing now cancels a pending switch, a newer request replaces an older one, and stopping
    /// drops it. A file that fails to load is logged and the current one plays on; one swapped in that no reader opens
    /// calls `didFail`. A player that has read nothing yet (it shows the still) takes `newURL` at once.
    func switchAtLoop(to newURL: URL, didSwitch: @escaping () -> Void, didFail: @escaping () -> Void) {
        guard !isStopped, newURL != pendingSwitch?.url else { return }
        guard newURL != url else {
            pendingSwitch = nil
            return
        }
        guard track != nil || isLoadingTrack else {
            wallpaperLog("[Video] switching \(url.lastPathComponent) to \(newURL.lastPathComponent) before it plays")
            url = newURL
            asset = makeAsset(newURL)
            pendingSwitch = nil
            didSwitch()
            // A decoding player gets here only after its file had no video track; the new file gets its own try.
            if wantsDecoding { startReading() }
            return
        }
        let newAsset = makeAsset(newURL)
        pendingSwitch = PendingSwitch(url: newURL, asset: newAsset, didSwitch: didSwitch, didFail: didFail)
        Task { [weak self] in
            let newTrack: AVAssetTrack?
            do {
                newTrack = try await newAsset.loadTracks(withMediaType: .video).first
            } catch {
                wallpaperLog("[Video] loading \(newURL.lastPathComponent) failed:", privateDetail: error.localizedDescription)
                newTrack = nil
            }
            let newCodec: FourCharCode? = if newTrack != nil { await videoCodec(of: newAsset) } else { nil }
            // Replaced, cancelled or stopped meanwhile, or the player is gone.
            guard let self, pendingSwitch?.asset === newAsset else { return }
            guard let newTrack else {
                wallpaperLog("[Video] no video track in \(newURL.lastPathComponent); \(url.lastPathComponent) plays on")
                pendingSwitch = nil
                return
            }
            pendingSwitch?.track = newTrack
            pendingSwitch?.codec = newCodec
        }
    }

    /// Drops a pending switch to `target`, whose file was copied again: its asset may read the old copy, and the next
    /// request for it loads it afresh.
    func cancelPendingSwitch(to target: URL) {
        guard pendingSwitch?.url == target else { return }
        pendingSwitch = nil
    }

    func stop() {
        isStopped = true
        wantsDecoding = false
        pendingSwitch = nil
        renderer.stopRequestingMediaData()
        reader?.cancelReading()
        withoutAnimation { layer.removeFromSuperlayer() }
    }

    private func pause() {
        CMTimebaseSetRate(timebase, rate: 0)
        renderer.stopRequestingMediaData()
        reader?.cancelReading()
        reader = nil
        output = nil
        guard track != nil, !isFlushing else { return }
        // Drops the frames queued past the paused one and frees the decoder; the paused frame stays.
        isFlushing = true
        renderer.flush(removingDisplayedImage: false) { [weak self] in
            Task { @MainActor in self?.flushFinished() }
        }
    }

    private func flushFinished() {
        isFlushing = false
        if wantsDecoding, !isStopped { startReading() }
    }

    /// Continues from the held frame (Phosphene's deep-pause wake), so a lock shows the same moment it left.
    private func startReading() {
        guard !isFlushing, reader == nil, !isStopped else { return }
        guard let track else {
            loadTrack()
            return
        }
        let now = CMTimebaseGetTime(timebase)
        var position = CMTimeSubtract(now, ptsOffset)
        // A loop that had run ahead of the held frame: start the clip over from here.
        if !position.isNumeric || position < .zero {
            ptsOffset = now
            position = .zero
        }
        if !openReader(track, from: position) {
            ptsOffset = now
            guard position > .zero, openReader(track, from: .zero) else {
                failUnreadSwitch()
                return
            }
        }
        lastEnqueuedEnd = now
        if let first = output?.copyNextSampleBuffer() {
            setDisplayImmediately(first)
            withoutAnimation { enqueue(first) }
        }
        CMTimebaseSetRate(timebase, rate: 1)
        feed()
    }

    private func loadTrack() {
        guard !isLoadingTrack else { return }
        isLoadingTrack = true
        Task {
            do {
                track = try await asset.loadTracks(withMediaType: .video).first
            } catch {
                wallpaperLog("[Video] loading \(url.lastPathComponent) failed:", privateDetail: error.localizedDescription)
            }
            if track != nil { codec = await videoCodec(of: asset) }
            isLoadingTrack = false
            guard track != nil else {
                wallpaperLog("[Video] no video track in \(url.lastPathComponent)")
                takePendingSwitchNow()
                return
            }
            if wantsDecoding { startReading() }
        }
    }

    /// The file this player started on never loaded, so a switch requested meanwhile has no loop to wait for.
    private func takePendingSwitchNow() {
        guard let pendingSwitch, !isStopped else { return }
        wallpaperLog("[Video] switching \(url.lastPathComponent) to \(pendingSwitch.url.lastPathComponent) before it plays")
        url = pendingSwitch.url
        asset = pendingSwitch.asset
        // nil while it still loads: startReading then loads it from this asset.
        track = pendingSwitch.track
        codec = pendingSwitch.codec
        self.pendingSwitch = nil
        pendingSwitch.didSwitch()
        if wantsDecoding { startReading() }
    }

    /// The file a switch swapped in can't be read: the player would hold its last frame, so its owner replaces it.
    private func failUnreadSwitch() {
        guard let didFail = unreadSwitchFailure else { return }
        unreadSwitchFailure = nil
        wallpaperLog("[Video] \(url.lastPathComponent) can't be read after the switch; the player is replaced")
        didFail()
    }

    private func openReader(_ track: AVAssetTrack, from position: CMTime) -> Bool {
        do {
            let newReader = try AVAssetReader(asset: asset)
            let newOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            newOutput.alwaysCopiesSampleData = false
            newReader.add(newOutput)
            // The reader starts at the keyframe before `position`; earlier frames show late, as in Phosphene.
            if position > .zero { newReader.timeRange = CMTimeRange(start: position, duration: .positiveInfinity) }
            guard newReader.startReading() else {
                wallpaperLog("[Video] startReading failed for \(url.lastPathComponent):",
                             privateDetail: newReader.error?.localizedDescription ?? "unknown error")
                return false
            }
            reader = newReader
            output = newOutput
            unreadSwitchFailure = nil
            return true
        } catch {
            wallpaperLog("[Video] AVAssetReader failed for \(url.lastPathComponent):", privateDetail: error.localizedDescription)
            return false
        }
    }

    private func feed() {
        renderer.requestMediaDataWhenReady(on: .main) { [weak self] in
            MainActor.assumeIsolated { self?.feedTick() }
        }
    }

    private func feedTick() {
        guard wantsDecoding, !isStopped else {
            renderer.stopRequestingMediaData()
            return
        }
        if renderer.status == .failed {
            // shortcut: no decoder-error recovery, the surface keeps its last frame; port Phosphene's
            // recreatePlayback if this shows up in the logs.
            wallpaperLog("[Video] renderer failed:", privateDetail: renderer.error?.localizedDescription ?? "unknown error")
            renderer.stopRequestingMediaData()
            return
        }
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        while renderer.isReadyForMoreMediaData {
            guard let sample = output?.copyNextSampleBuffer() else {
                renderer.stopRequestingMediaData()
                // Later: requestMediaDataWhenReady is not reentrant.
                Task { [weak self] in self?.loopToStart() }
                return
            }
            enqueue(sample)
        }
    }

    private func loopToStart() {
        guard wantsDecoding, !isStopped, track != nil else { return }
        // A pass that enqueued nothing would loop forever on the main thread.
        guard lastEnqueuedEnd > ptsOffset else {
            wallpaperLog("[Video] \(url.lastPathComponent) gave no frames; holding the last one")
            return
        }
        ptsOffset = lastEnqueuedEnd
        if swapInLoadedSwitch() {
            wallpaperLog("[Video] codec changes at the loop; flushing before \(url.lastPathComponent)")
            // Keeps the frame on screen; once the flush ends, reading starts the new file from its start.
            pause()
            return
        }
        guard let track, openReader(track, from: .zero) else {
            failUnreadSwitch()
            return
        }
        feed()
    }

    /// Takes a loaded switch. True when its codec differs from the current one, or either is unknown: the display layer
    /// takes a new format description of the same codec with its first sample, but is flushed before another codec.
    private func swapInLoadedSwitch() -> Bool {
        guard let pendingSwitch, let newTrack = pendingSwitch.track else { return false }
        wallpaperLog("[Video] switching \(url.lastPathComponent) to \(pendingSwitch.url.lastPathComponent) at the loop")
        let codecChanges = codec == nil || pendingSwitch.codec != codec
        url = pendingSwitch.url
        asset = pendingSwitch.asset
        track = newTrack
        codec = pendingSwitch.codec
        self.pendingSwitch = nil
        unreadSwitchFailure = pendingSwitch.didFail
        pendingSwitch.didSwitch()
        return codecChanges
    }

    private func enqueue(_ sample: CMSampleBuffer) {
        let adjusted = offsetTiming(sample)
        let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
        let duration = CMSampleBufferGetDuration(adjusted)
        // Max, not last, handles B-frame reordering; invalid-PTS padding samples are skipped.
        if pts.isValid {
            let end = CMTimeAdd(pts, duration.isValid && duration > .zero ? duration : CMTime(value: 1, timescale: 60))
            if end > lastEnqueuedEnd { lastEnqueuedEnd = end }
        }
        renderer.enqueue(adjusted)
    }

    /// Shifts DTS/PTS by the loop offset; the copy shares the sample data.
    private func offsetTiming(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsOffset > .zero else { return sample }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid
        )
        var adjusted: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &adjusted
        )
        return status == noErr ? adjusted ?? sample : sample
    }
}
