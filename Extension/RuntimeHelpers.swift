// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.
//
// Builders for the private WallpaperExtensionKit XPC value classes, and Mirror
// readers for the request objects WallpaperAgent sends.

import Foundation
@preconcurrency import IOSurface
import QuartzCore

/// A private class this file writes into by raw offset: the ivar must sit exactly where it was observed.
private struct IvarLayout {
    let className: String
    let ivarName: String
    let offset: Int
    let instanceSize: Int

    /// Observed on macOS 27.2.1 (26B131): both classes are 16-byte NSObject subclasses whose single
    /// pointer-sized ivar sits at offset 8. A macOS update that moves either one turns the raw writes off.
    static let remoteContext = IvarLayout(className: "WallpaperRemoteContextXPC", ivarName: "box", offset: 8, instanceSize: 16)
    static let snapshot = IvarLayout(className: "WallpaperSnapshotXPC", ivarName: "rawValue", offset: 8, instanceSize: 16)

    /// nil when the class, its ivar (looked up by name), the ivar's offset and the instance size all match.
    func mismatch() -> String? {
        guard let cls = objc_getClass(className) as? AnyClass else { return "\(className) missing" }
        guard let ivar = class_getInstanceVariable(cls, ivarName) else { return "\(className).\(ivarName) missing" }
        let found = (offset: ivar_getOffset(ivar), size: class_getInstanceSize(cls))
        guard found.offset == offset, found.size == instanceSize else {
            return "\(className).\(ivarName) offset \(found.offset) size \(found.size), expected \(offset)/\(instanceSize)"
        }
        return nil
    }
}

/// Checked once, on first use after WallpaperExtensionKit is loaded. False: every acquire and snapshot replies
/// with an error and nothing is written.
let runtimeLayoutIsValid: Bool = {
    let mismatches = [IvarLayout.remoteContext, IvarLayout.snapshot].compactMap { $0.mismatch() }
    wallpaperLog(mismatches.isEmpty
        ? "[Layout] verified: WallpaperRemoteContextXPC.box and WallpaperSnapshotXPC.rawValue at offset 8, size 16"
        : "[Layout] MISMATCH, acquire and snapshot disabled: \(mismatches.joined(separator: "; "))")
    return mismatches.isEmpty
}()

/// Startup self-check: logs any missing private class and verifies the raw-write layout.
func verifyRuntimeLayout() {
    let critical = [
        "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperCreationRequestXPC",
        "WallpaperSettingsViewModelsXPC", "WallpaperIDXPC",
    ]
    let missing = critical.filter { objc_getClass($0) == nil }
    wallpaperLog(missing.isEmpty ? "SelfCheck OK" : "SelfCheck MISSING: \(missing.joined(separator: ", "))")
    _ = runtimeLayoutIsValid
}

let runtimeLayoutError = wallpaperError(6, "WallpaperExtensionKit layout changed; Glowdrop is disabled")

/// A new instance of `layout`'s class with `value` stored in its ivar; nil (no write) unless the layout verified.
/// The mismatch itself was logged once by `runtimeLayoutIsValid`.
private func makeInstance<Value: BitwiseCopyable>(_ layout: IvarLayout, storing value: Value) -> AnyObject? {
    guard runtimeLayoutIsValid else { return nil }
    guard let cls = objc_getClass(layout.className) as? AnyClass, let instance = class_createInstance(cls, 0) else {
        wallpaperLog("ERROR: could not create \(layout.className)")
        return nil
    }
    let obj = instance as AnyObject
    Unmanaged.passUnretained(obj).toOpaque().advanced(by: layout.offset).storeBytes(of: value, as: Value.self)
    return obj
}

/// WallpaperRemoteContextXPC wrapping a CAContext id (a UInt32 in its `box` ivar).
func createRemoteContextXPC(contextId: UInt32) -> AnyObject? {
    makeInstance(.remoteContext, storing: contextId)
}

/// WallpaperSnapshotXPC wrapping an IOSurface (a retained pointer in its `rawValue` ivar).
func createSnapshotXPC(surface: IOSurface) -> AnyObject? {
    let retained = Unmanaged.passRetained(surface)
    guard let obj = makeInstance(.snapshot, storing: UnsafeRawPointer(retained.toOpaque())) else {
        retained.release()
        return nil
    }
    return obj
}

/// A private CAContext, reached only through selectors checked with responds(to:): the binary keeps no
/// link-time reference to the class, and a changed API fails with a log line instead of a crash.
struct RemoteContext {
    let object: NSObject
    let contextId: UInt32

    init?(displayID: UInt32?) {
        let withOptions = NSSelectorFromString("remoteContextWithOptions:")
        let plain = NSSelectorFromString("remoteContext")
        guard let cls = NSClassFromString("CAContext") as? NSObject.Type else {
            wallpaperLog("ERROR: CAContext class not found")
            return nil
        }
        let raw: Any? = if let displayID, cls.responds(to: withOptions) {
            cls.perform(withOptions, with: ["displayId": displayID])?.takeUnretainedValue()
        } else if cls.responds(to: plain) {
            cls.perform(plain)?.takeUnretainedValue()
        } else {
            nil
        }
        guard let object = raw as? NSObject, object.responds(to: NSSelectorFromString("contextId")),
              object.responds(to: NSSelectorFromString("setLayer:")),
              let contextId = (object.value(forKey: "contextId") as? NSNumber)?.uint32Value, contextId != 0 else {
            wallpaperLog("ERROR: remote CAContext creation failed")
            return nil
        }
        self.object = object
        self.contextId = contextId
    }

    func host(_ layer: CALayer) {
        object.setValue(layer, forKey: "layer")
    }

    /// Forces the WindowServer to reclaim the context; dropping the reference is not enough.
    func invalidate() {
        let sel = NSSelectorFromString("invalidate")
        guard object.responds(to: sel) else { return }
        object.perform(sel)
    }
}

/// The WallpaperID's UUID: one per Space, lock-screen surface, or Settings preview.
func extractWallpaperUUID(fromID id: Any?) -> UUID? {
    guard let id else { return nil }
    return searchUUID(id, depth: 0)
}

private func searchUUID(_ value: Any, depth: Int) -> UUID? {
    guard depth < 8 else { return nil }
    if let uuid = value as? UUID { return uuid }
    for child in Mirror(reflecting: value).children {
        if let found = searchUUID(child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// Stable per-display UUID for an acquire whose id carries none.
func fallbackUUID(forDisplay displayID: UInt32) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", displayID)) ?? UUID()
}

/// An enum value's case name read through Mirror, not a stringified description whose format can change.
func enumCaseName(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .enum, let label = mirror.children.first?.label { return label }
    return String(describing: value)
}

/// Shallow recursive search of a value's Mirror for a stored property label.
func mirrorFindProperty(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 6 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == label { return child.value }
        if let found = mirrorFindProperty(label, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// Geometry, role and choice read from a WallpaperCreationRequestXPC (`rawValue.destination`, `isPreview`,
/// `rawValue.descriptor.configuration`).
struct AcquireParams: Sendable {
    var size = CGSize(width: 2_560, height: 1_440)
    var scale: CGFloat = 2.0
    var displayID: UInt32?
    var isPreview = false
    /// The picked tile's configuration as UTF-8; nil when the request carries none.
    var choice: String?

    init(request: Any?) {
        guard let request else { return }
        if let destination = mirrorFindProperty("destination", in: request) {
            // Direct children only, as Phosphene reads them; a deep search could hit a nested `size`.
            let fields = directChildren(of: destination)
            if let size = fields["size"] as? CGSize { self.size = size }
            if let scale = fields["scaleFactor"] as? CGFloat { self.scale = scale }
            displayID = fields["directDisplayID"] as? UInt32
        }
        if let descriptor = mirrorFindProperty("descriptor", in: request),
           let configuration = directChildren(of: descriptor)["configuration"] as? Data, !configuration.isEmpty {
            choice = String(data: configuration, encoding: .utf8)
        }
        isPreview = (mirrorFindProperty("isPreview", in: request) as? Bool) ?? false
    }
}

/// A value's labelled stored properties, first label wins.
private func directChildren(of value: Any) -> [String: Any] {
    Dictionary(
        Mirror(reflecting: value).children.compactMap { child in child.label.map { ($0, child.value) } },
        uniquingKeysWith: { first, _ in first }
    )
}
