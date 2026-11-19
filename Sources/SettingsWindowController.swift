import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let settings: AppSettings
    private let library: VideoLibrary
    private var window: NSWindow?
    private var titleSubscription: AnyCancellable?

    init(settings: AppSettings, library: VideoLibrary) {
        self.settings = settings
        self.library = library
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings, library: library))
        window.isReleasedWhenClosed = false
        window.center()
        // AppSettings switches L10n in willSet, before this sink runs, so the title is already in the new language.
        titleSubscription = settings.$language.sink { [weak window] _ in
            window?.title = L10n.t("settings.title")
        }
        return window
    }
}
