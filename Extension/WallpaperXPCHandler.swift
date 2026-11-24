// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.

import AppKit
import Foundation
import os

/// WallpaperAgent's calls arrive on XPC threads. Requests are read here (Mirror, value types only)
/// and the work hops to the main actor in arrival order.
final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    /// WallpaperAgent's end of this connection: set in `accept` before the connection resumes, cleared when it
    /// ends. Locked because XPC callbacks read it while the invalidation handler clears it.
    private let storedAgentProxy = OSAllocatedUnfairLock<(any WallpaperExtensionProxyXPCProtocol)?>(uncheckedState: nil)
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)? {
        get { storedAgentProxy.withLockUnchecked { $0 } }
        set { storedAgentProxy.withLockUnchecked { $0 = newValue } }
    }

    private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    // MARK: - Lifecycle

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        guard runtimeLayoutIsValid else {
            reply(nil, runtimeLayoutError)
            return
        }
        let params = AcquireParams(request: request)
        let key = extractWallpaperUUID(fromID: id) ?? fallbackUUID(forDisplay: params.displayID ?? 0)
        onMain { SurfaceStore.shared.acquire(key: key, params: params, reply: reply) }
    }

    /// A field that can't be found reads as the benign desktop-active value, as in Phosphene.
    func update(withId id: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let key = extractWallpaperUUID(fromID: id)
        let mode = request.flatMap { mirrorFindProperty("presentationMode", in: $0) }
            .map { PresentationMode(caseName: enumCaseName($0)) } ?? .desktop
        let activity = request.flatMap { mirrorFindProperty("activityState", in: $0) }
            .map { ActivityState(caseName: enumCaseName($0)) } ?? .active
        onMain { SurfaceStore.shared.update(key: key, mode: mode, activity: activity) }
        reply(nil)
    }

    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let key = extractWallpaperUUID(fromID: id)
        onMain {
            SurfaceStore.shared.invalidate(key: key)
            reply(nil)
        }
    }

    func snapshot(withId id: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        guard runtimeLayoutIsValid else {
            reply(nil, runtimeLayoutError)
            return
        }
        let key = extractWallpaperUUID(fromID: id)
        Task { @MainActor in
            let snapshot = await makeSnapshotXPC(for: key)
            wallpaperLog("SNAPSHOT replied \(snapshot == nil ? "nil" : "IOSurface")")
            reply(snapshot, nil)
        }
    }

    // MARK: - Settings

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        Task { @MainActor in
            let models = await buildSettingsViewModelsXPC()
            wallpaperLog("PROVIDE SETTINGS VIEW MODELS -> \(models.map { NSStringFromClass(type(of: $0)) } ?? "nil (remap failed)")")
            reply(models, models == nil ? wallpaperError(5, "Settings view model remap failed") : nil)
        }
    }

    // MARK: - Choices

    func addChoiceRequest(withChoiceRequest _: Any?, onBehalfOfProcess _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    /// The acquire that follows a pick carries the choice; this only makes the agent fetch the new stills.
    func selectedChoicesDidChange(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        wallpaperLog("SELECTED CHOICES DID CHANGE")
        agentProxy?.invalidateSnapshots { error in
            if let error { wallpaperLog("[Choice] invalidateSnapshots failed:", privateDetail: error.localizedDescription) }
        }
        reply(nil)
    }

    /// A tile menu item (see SettingsProvider) opens its glowdrop:// link in the app, as in Phosphene. Only the ids
    /// this extension serves open anything.
    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID _: Any?,
                                 reply: @escaping @Sendable ((any Error)?) -> Void) {
        guard let link = (menuItemID as? String).flatMap(GlowdropLink.init(rawValue:)) else {
            wallpaperLog("CONTEXT MENU unknown item ignored:", privateDetail: (menuItemID as? String) ?? "not a string")
            reply(nil)
            return
        }
        onMain {
            let opened = NSWorkspace.shared.open(link.url)
            wallpaperLog("CONTEXT MENU \(link.rawValue) opened=\(opened)")
        }
        reply(nil)
    }

    // MARK: - Downloads

    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (NSNumber?, (any Error)?) -> Void) {
        reply(NSNumber(value: true), nil)
    }

    func download(withChoiceID _: Any?, reply: ((any Error)?) -> Void) -> Any? {
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }

    // MARK: - Migration, shuffle, debug

    func migrateSelectedChoice(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) { reply(nil, nil) }
    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) { reply(false, nil) }
    func handleDebugRequest(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) { reply(nil, nil) }
    func handleNotification(withNamed _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
}
