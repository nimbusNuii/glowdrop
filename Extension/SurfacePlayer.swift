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

@MainActor
final class SurfacePlayer {
    private let url: URL
    private let layer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private let asset: AVURLAsset
    private var track: AVAssetTrack?
    private var isLoadingTrack = false
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// A pause's flush is in flight; reading starts again only after it, never alongside it.
    private var isFlushing = false
    private var wantsDecoding = false
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
        asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey:
                                                   AVAssetReferenceRestrictions.forbidAll.rawValue])
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

    func stop() {
        isStopped = true
        wantsDecoding = false
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
            guard position > .zero, openReader(track, from: .zero) else { return }
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
            isLoadingTrack = false
            guard track != nil else {
                wallpaperLog("[Video] no video track in \(url.lastPathComponent)")
                return
            }
            if wantsDecoding { startReading() }
        }
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
        guard wantsDecoding, !isStopped, let track else { return }
        // A pass that enqueued nothing would loop forever on the main thread.
        guard lastEnqueuedEnd > ptsOffset else {
            wallpaperLog("[Video] \(url.lastPathComponent) gave no frames; holding the last one")
            return
        }
        ptsOffset = lastEnqueuedEnd
        guard openReader(track, from: .zero) else { return }
        feed()
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
