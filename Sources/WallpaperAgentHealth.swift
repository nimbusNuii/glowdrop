import Darwin
import Foundation
import os

/// Detects a Glowdrop wallpaper extension that macOS stopped, and restarts the Wallpaper Agent to reload it.
enum WallpaperAgentHealth {
    static let extensionProvider = "io.github.nimbusnuii.glowdrop.wallpaper"
    private static let extensionPathSuffix = "/GlowdropWallpaper.appex/Contents/MacOS/GlowdropWallpaper"
    private static let maxIndexBytes = 1_048_576
    private static let maxDepth = 12
    private static let pathBufferSize = 4096

    /// True when any `Provider` key in the wallpaper store names the Glowdrop extension.
    static func usesGlowdrop(indexPlist data: Data) -> Bool {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return false
        }
        return containsProvider(root, depth: 0)
    }

    private static func containsProvider(_ node: Any, depth: Int) -> Bool {
        guard depth <= maxDepth else { return false }
        if let dictionary = node as? [String: Any] {
            if dictionary["Provider"] as? String == extensionProvider { return true }
            return dictionary.values.contains { containsProvider($0, depth: depth + 1) }
        }
        if let array = node as? [Any] {
            return array.contains { containsProvider($0, depth: depth + 1) }
        }
        return false
    }

    static func isGlowdropSelected() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxIndexBytes) else { return false }
        return usesGlowdrop(indexPlist: data)
    }

    /// Fails closed: true when the process list can't be read, so the agent is never restarted on uncertainty.
    static func isExtensionRunning() -> Bool {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(expected) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return true }
        var path = [CChar](repeating: 0, count: pathBufferSize)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix(extensionPathSuffix) { return true }
        }
        return false
    }

    /// launchd starts the agent again by itself, which reloads a stuck wallpaper extension. Blocks: call off the main thread.
    static func restartAgent(logger: Logger) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                logger.error("killall WallpaperAgent exited with status \(process.terminationStatus, privacy: .public)")
            }
        } catch {
            logger.error("Couldn’t run killall WallpaperAgent: \(error.localizedDescription, privacy: .private)")
        }
    }
}
