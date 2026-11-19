import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import VideoToolbox

/// HEVC .mp4 writer fed with BGRA pixel buffers from the adaptor's pool.
final class VideoEncoder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let timescale: Int32

    init(url: URL, width: Int, height: Int, fps: Int, bitrate: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video,
                                   outputSettings: Self.outputSettings(width: width, height: height,
                                                                       fps: fps, bitrate: bitrate))
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        timescale = Int32(fps)
        guard writer.canAdd(input) else { throw RenderError("writer rejected the HEVC input settings") }
        writer.add(input)
        guard writer.startWriting() else { throw failure("cannot start writing") }
        writer.startSession(atSourceTime: .zero)
    }

    func makeBuffer() throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else { throw failure("pixel buffer pool unavailable") }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw RenderError("cannot allocate pixel buffer (CVReturn \(status))")
        }
        return buffer
    }

    func append(_ buffer: CVPixelBuffer, frame: Int) throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw failure("writer stopped while waiting") }
            Thread.sleep(forTimeInterval: 0.002)
        }
        let time = CMTime(value: CMTimeValue(frame), timescale: timescale)
        guard adaptor.append(buffer, withPresentationTime: time) else { throw failure("append failed at frame \(frame)") }
    }

    func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw failure("finishing failed") }
    }

    private func failure(_ message: String) -> RenderError {
        RenderError("\(message): \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
    }

    private static func outputSettings(width: Int, height: Int, fps: Int, bitrate: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }
}
