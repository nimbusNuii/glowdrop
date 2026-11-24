// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.

import Foundation
import os

/// Pushes fresh settings view models to every live WallpaperAgent connection. The agent caches the tiles and
/// asks again only after a (re)install or an OS update, so a catalog change would otherwise never show.
enum SettingsPush {
    private static let debounce: TimeInterval = 0.5

    /// Weak, so a connection that ends without unregistering can't keep its handler alive.
    private struct WeakHandler {
        weak var handler: WallpaperXPCHandler?
    }

    /// Registered from `accept` and cleared from invalidation handlers, on XPC threads.
    private static let handlers = OSAllocatedUnfairLock(uncheckedState: [WeakHandler]())
    @MainActor private static var pending: DispatchWorkItem?
    /// One push at a time; a catalog change during it asks for one more push once it ends.
    @MainActor private static var isPushing = false
    @MainActor private static var needsRerun = false
    /// Bumped by every catalog change; a push built before the latest change is not sent.
    @MainActor private static var generation = 0

    static func register(_ handler: WallpaperXPCHandler) {
        handlers.withLockUnchecked {
            $0.removeAll { $0.handler == nil }
            $0.append(WeakHandler(handler: handler))
        }
    }

    static func unregister(_ handler: WallpaperXPCHandler) {
        handlers.withLockUnchecked { $0.removeAll { $0.handler == nil || $0.handler === handler } }
    }

    /// Debounced: a burst of catalog writes becomes one rebuild half a second after the last one.
    @MainActor static func catalogDidChange() {
        generation += 1
        guard !isPushing else {
            needsRerun = true
            return
        }
        schedulePush()
    }

    @MainActor private static func schedulePush() {
        pending?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                pending = nil
                Task { await pushOnce() }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Single flight: one push's thumbnail cleanup never runs in the middle of another push.
    @MainActor private static func pushOnce() async {
        guard !isPushing else {
            needsRerun = true
            return
        }
        isPushing = true
        await push()
        isPushing = false
        guard needsRerun else { return }
        needsRerun = false
        schedulePush()
    }

    /// Builds the view models once and sends them over every live connection, unless the catalog changed meanwhile.
    @MainActor private static func push() async {
        let started = generation
        guard let models = await buildSettingsViewModelsXPC(attempts: 1) else {
            wallpaperLog("[SettingsPush] build failed; nothing pushed")
            return
        }
        guard generation == started else {
            wallpaperLog("[SettingsPush] catalog changed during the build; pushing again")
            return
        }
        send(models)
    }

    /// After a catalog video was copied again under the same name: every live agent fetches the stills anew, as after
    /// a pick (see `WallpaperXPCHandler.selectedChoicesDidChange`).
    @MainActor static func invalidateSnapshots() {
        let proxies = liveProxies()
        wallpaperLog("[SettingsPush] invalidating snapshots on \(proxies.count) connection(s)")
        for proxy in proxies {
            proxy.invalidateSnapshots { error in
                guard let error else { return }
                wallpaperLog("[SettingsPush] invalidateSnapshots failed:", privateDetail: error.localizedDescription)
            }
        }
    }

    private static func liveProxies() -> [any WallpaperExtensionProxyXPCProtocol] {
        handlers.withLockUnchecked { $0.compactMap { $0.handler?.agentProxy } }
    }

    /// Synchronous: the agent's reply is only logged, so nothing waits for it.
    private static func send(_ models: AnyObject) {
        let proxies = liveProxies()
        guard !proxies.isEmpty else {
            wallpaperLog("[SettingsPush] no live connection; the agent gets the tiles on its next query")
            return
        }
        wallpaperLog("[SettingsPush] pushing to \(proxies.count) connection(s)")
        for proxy in proxies {
            proxy.updateSettingsViewModels(models) { error in
                if let error { wallpaperLog("[SettingsPush] update failed:", privateDetail: error.localizedDescription) }
            }
        }
    }
}
