// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.

import ExtensionFoundation
import Foundation

struct WallpaperExtensionConfig: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        wallpaperLog("XPC from pid=\(connection.processIdentifier)")
        // setCodeSigningRequirement crashes on ExtensionKit (BoardServices) connections on macOS 27.2 (SIGSEGV in xpc_connection_set_peer_code_signing_requirement) — do not use.
        guard CallerValidation.isAcceptable(connection) else {
            wallpaperLog("XPC rejected: caller not Apple-signed")
            return false
        }
        connection.exportedInterface = makeExportedInterface()
        connection.remoteObjectInterface = NSXPCInterface(with: (any WallpaperExtensionProxyXPCProtocol).self)
        let handler = WallpaperXPCHandler()
        connection.exportedObject = handler
        connection.interruptionHandler = { wallpaperLog("XPC interrupted") }
        connection.invalidationHandler = { [weak handler] in
            wallpaperLog("XPC invalidated")
            guard let handler else { return }
            handler.agentProxy = nil
            SettingsPush.unregister(handler)
        }
        // Before resume, so an early callback never sees a nil proxy.
        handler.agentProxy = connection.remoteObjectProxy as? (any WallpaperExtensionProxyXPCProtocol)
        SettingsPush.register(handler)
        connection.resume()
        wallpaperLog("XPC accepted")
        return true
    }
}

/// Private WallpaperExtensionKit value types that may cross the wire, plus Foundation basics.
private func makeAllowedClasses() -> Set<AnyHashable> {
    let typeNames = [
        "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC",
        "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC",
        "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperExtensionChoiceRequestXPC",
        "WallpaperChoiceRequestAdditionResultXPC", "WallpaperDebugRequestXPC", "WallpaperDebugResponseXPC",
        "WallpaperMigrationVersionXPC", "WallpaperSettingsViewModelsXPC", "AuditTokenXPC",
    ]
    let found = typeNames.compactMap { objc_getClass($0) as? AnyClass }
    if found.count != typeNames.count {
        let missing = typeNames.filter { objc_getClass($0) == nil }
        wallpaperLog("MISSING XPC types: \(missing.joined(separator: ", "))")
    }
    let foundation: [AnyClass] = [
        NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self, NSError.self,
    ]
    // Not a fallible path: an NSSet always bridges to Set<AnyHashable>.
    return NSSet(array: found + foundation) as! Set<AnyHashable>
}

private func makeExportedInterface() -> NSXPCInterface {
    let exported = NSXPCInterface(with: (any WallpaperExtensionXPCProtocol).self)
    let classes = makeAllowedClasses()
    typealias H = WallpaperXPCHandler
    // (selector, argument index, isReply) — same allow-list Phosphene registers.
    let slots: [(Selector, Int, Bool)] = [
        (#selector(H.acquire(withId:request:reply:)), 0, false),
        (#selector(H.acquire(withId:request:reply:)), 1, false),
        (#selector(H.acquire(withId:request:reply:)), 0, true),
        (#selector(H.update(withId:request:reply:)), 0, false),
        (#selector(H.update(withId:request:reply:)), 1, false),
        (#selector(H.invalidate(withId:reply:)), 0, false),
        (#selector(H.snapshot(withId:reply:)), 0, false),
        (#selector(H.snapshot(withId:reply:)), 0, true),
        (#selector(H.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
        (#selector(H.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
        (#selector(H.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
        (#selector(H.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
        (#selector(H.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, true),
        (#selector(H.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
        (#selector(H.selectedChoicesDidChange(for:reply:)), 0, false),
        (#selector(H.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
        (#selector(H.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
        (#selector(H.isChoiceDownloaded(with:reply:)), 0, false),
        (#selector(H.download(withChoiceID:reply:)), 0, false),
        (#selector(H.pauseDownload(for:reply:)), 0, false),
        (#selector(H.cancelDownload(for:reply:)), 0, false),
        (#selector(H.resumeDownload(for:reply:)), 0, false),
        (#selector(H.removeDownload(for:reply:)), 0, false),
        (#selector(H.migrateSelectedChoice(for:reply:)), 0, false),
        (#selector(H.migrateSelectedChoice(for:reply:)), 0, true),
        (#selector(H.migrate(from:to:reply:)), 0, false),
        (#selector(H.migrate(from:to:reply:)), 1, false),
        (#selector(H.skipShuffledContent(withId:reply:)), 0, false),
        (#selector(H.canSkipShuffledContent(withId:reply:)), 0, false),
        (#selector(H.handleDebugRequest(for:reply:)), 0, false),
        (#selector(H.handleDebugRequest(for:reply:)), 0, true),
        (#selector(H.handleNotification(withNamed:reply:)), 0, false),
    ]
    for (sel, index, isReply) in slots {
        exported.setClasses(classes, for: sel, argumentIndex: index, ofReply: isReply)
    }
    return exported
}
