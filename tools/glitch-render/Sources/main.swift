import CoreImage
import CoreVideo
import Foundation
import Metal

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Colour management is disabled so hex colours in the code are the pixel values written.
func makeContext() throws -> CIContext {
    guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError("no Metal device available") }
    return CIContext(mtlDevice: device, options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
    ])
}

func renderStill(_ scene: SceneRenderer, frame: Int, to path: String, context: CIContext) throws {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw RenderError("sRGB colour space unavailable") }
    let url = URL(fileURLWithPath: path)
    try context.writePNGRepresentation(of: scene.image(forFrame: frame), to: url, format: .RGBA8, colorSpace: space)
    print("wrote frame \(frame) → \(url.path)")
}

func renderVideo(_ scene: SceneRenderer, options: RenderOptions, outPath: String, context: CIContext) throws {
    let url = URL(fileURLWithPath: outPath)
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
    let encoder = try VideoEncoder(url: url, width: options.width, height: options.height,
                                   fps: options.fps, bitrate: options.bitrate)
    let total = options.fps * options.seconds
    let started = Date()
    for frame in 0..<total {
        try autoreleasepool {
            let buffer = try encoder.makeBuffer()
            let destination = CIRenderDestination(pixelBuffer: buffer)
            destination.colorSpace = nil
            try context.startTask(toRender: scene.image(forFrame: frame), to: destination).waitUntilCompleted()
            try encoder.append(buffer, frame: frame)
        }
        if (frame + 1) % 60 == 0 {
            print(String(format: "frame %d/%d  %.1fs", frame + 1, total, Date().timeIntervalSince(started)))
        }
    }
    try encoder.finish()
    print(String(format: "done: %d frames in %.1fs → %@", total, Date().timeIntervalSince(started), url.path))
}

let options: RenderOptions
do {
    options = try RenderOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)\n\(RenderOptions.usage)")
}

do {
    try Compositing.validateFilters()
    let context = try makeContext()
    let timeline = Timeline(fps: options.fps, seconds: options.seconds)
    let scene = try SceneRenderer(width: options.width, height: options.height, timeline: timeline, context: context,
                                  palette: options.palette, logoMask: options.logoMask, hudText: options.hudText)
    if let frame = options.stillFrame, let png = options.pngPath {
        try renderStill(scene, frame: frame, to: png, context: context)
    } else if let out = options.outPath {
        try renderVideo(scene, options: options, outPath: out, context: context)
    }
} catch {
    fail("\(error)")
}
