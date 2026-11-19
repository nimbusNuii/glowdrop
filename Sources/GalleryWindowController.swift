import AppKit
import SwiftUI

@MainActor
final class GalleryWindowController {
    private let library: VideoLibrary
    private let settings: AppSettings
    private var window: NSWindow?

    init(library: VideoLibrary, settings: AppSettings) {
        self.library = library
        self.settings = settings
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        // A hosting controller (not a bare view) lets the SwiftUI toolbar and search field reach the window.
        let host = NSHostingController(rootView: GalleryView(library: library).environmentObject(settings))
        if #available(macOS 14, *) { host.sceneBridgingOptions = [.toolbars] }
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "Glowdrop"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.library.rescan() }
        }
        return window
    }
}
