import AppKit
import ServiceManagement
import SwiftUI

/// View-local state for the Settings window (no @State: the CLT toolchain lacks the macro plugin).
@MainActor
final class SettingsState: ObservableObject {
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginMessage: String?
    @Published var libraryError: String?

    func refreshLogin() {
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? L10n.t("settings.loginApproval") : nil
        } catch {
            loginMessage = L10n.f("settings.loginError", error.localizedDescription)
        }
        refreshLogin()
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: VideoLibrary
    @ObservedObject var lockScreen: LockScreenSync
    @StateObject private var state = SettingsState()

    private static let wallpaperSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        Form {
            general
            if #available(macOS 26, *) { engineSection }
            playback
            energy
            // The system engine always covers the Lock Screen.
            if #available(macOS 26, *) {
                if !settings.usesSystemEngine { lockScreenSection }
            }
            librarySection
            about
        }
        .formStyle(.grouped)
        .tint(Theme.neon)
        .frame(width: 520, height: 680)
        .onAppear { state.refreshLogin() }
    }

    private var general: some View {
        Section(L10n.t("settings.general")) {
            Toggle(L10n.t("settings.openAtLogin"),
                   isOn: Binding(get: { state.opensAtLogin }, set: { state.setOpensAtLogin($0) }))
            if let message = state.loginMessage { footnote(message) }
            Picker(L10n.t("settings.language"), selection: $settings.language) {
                Text(verbatim: L10n.t("settings.language.system")).tag(AppLanguage.system)
                Text(verbatim: "ไทย").tag(AppLanguage.thai)
                Text(verbatim: "English").tag(AppLanguage.english)
            }
        }
    }

    private var engineSection: some View {
        Section {
            Picker(L10n.t("settings.engine"), selection: $settings.engine) {
                Text(verbatim: L10n.t("settings.engine.window")).tag(WallpaperEngine.window)
                Text(verbatim: L10n.t("settings.engine.system")).tag(WallpaperEngine.system)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            footnote(L10n.t(settings.usesSystemEngine ? "settings.engine.system.footnote"
                                                      : "settings.engine.window.footnote"))
            if settings.usesSystemEngine {
                shufflePicker
                wallpaperSettingsControls
            }
        } header: {
            Text(verbatim: L10n.t("settings.engine"))
        }
    }

    /// How often the Shuffle tile in Wallpaper Settings moves to another video.
    private var shufflePicker: some View {
        Picker(L10n.t("settings.shuffle"), selection: $settings.shuffleInterval) {
            Text(verbatim: L10n.t("settings.shuffle.5min")).tag(300)
            Text(verbatim: L10n.t("settings.shuffle.15min")).tag(900)
            Text(verbatim: L10n.t("settings.shuffle.hour")).tag(3_600)
            Text(verbatim: L10n.t("settings.shuffle.day")).tag(86_400)
        }
    }

    private var playback: some View {
        Section(L10n.t("settings.playback")) {
            Picker(L10n.t("settings.quality"), selection: $settings.quality) {
                Text(verbatim: L10n.t("settings.quality.auto")).tag(QualityPreference.auto)
                Text(verbatim: "2K").tag(QualityPreference.twoK)
                Text(verbatim: "4K").tag(QualityPreference.fourK)
            }
            footnote(L10n.t("settings.quality.footnote"))
        }
    }

    private var energy: some View {
        Section {
            Toggle(L10n.t("settings.pauseCovered"), isOn: $settings.pauseWhenCovered)
            // It pauses only Glowdrop's windows; macOS decides when its own Lock Screen plays.
            if !settings.usesSystemEngine {
                Toggle(L10n.t("settings.pauseLocked"), isOn: $settings.pauseWhenLocked)
            }
            Toggle(L10n.t("settings.pauseLowPower"), isOn: $settings.pauseInLowPowerMode)
            Toggle(L10n.t("settings.pauseBattery"), isOn: $settings.pauseOnBattery)
            Toggle(L10n.t("settings.pauseReduceMotion"), isOn: $settings.pauseWithReduceMotion)
        } header: {
            Text(verbatim: L10n.t("settings.energy"))
        } footer: {
            footnote(L10n.t("settings.offline"))
        }
    }

    private var lockScreenSection: some View {
        Section {
            Toggle(L10n.t("settings.lockScreen.show"), isOn: $settings.lockScreenSync)
            wallpaperSettingsControls
        } header: {
            Text(verbatim: L10n.t("settings.lockScreen"))
        } footer: {
            footnote(L10n.t("settings.lockScreen.footnote"))
        }
    }

    /// Shared by both engines' sections: the way to System Settings and the last shared-folder error.
    @ViewBuilder private var wallpaperSettingsControls: some View {
        if let url = Self.wallpaperSettingsURL {
            Button(L10n.t("settings.lockScreen.open")) { NSWorkspace.shared.open(url) }
        }
        if let error = lockScreen.lastError {
            Text(verbatim: L10n.text(error)).font(.caption).foregroundColor(.red)
        }
    }

    private var librarySection: some View {
        Section(L10n.t("settings.library")) {
            LabeledContent(L10n.t("settings.libraryFolder")) {
                Text(verbatim: (settings.libraryPath as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle)
                    .help(settings.libraryPath)
            }
            HStack {
                Button(L10n.t("settings.change")) { chooseFolder() }
                Button(L10n.t("common.showInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([library.libraryRoot])
                }
                Button(L10n.t("common.refresh")) { library.rescan() }
            }
            if let error = state.libraryError { Text(verbatim: error).font(.caption).foregroundColor(.red) }
        }
    }

    private var about: some View {
        Section(L10n.t("settings.about")) {
            LabeledContent {
                Text(verbatim: L10n.f("settings.version", version))
            } label: {
                Text(verbatim: appName)
            }
            footnote(L10n.t("settings.description"))
            footnote(L10n.t("settings.openSource"))
            if let licenseURL = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") {
                Button(L10n.t("settings.viewLicense")) { NSWorkspace.shared.open(licenseURL) }
            }
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Glowdrop"
    }

    private func footnote(_ text: String) -> some View {
        Text(verbatim: text).font(.caption).foregroundColor(.secondary)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = library.libraryRoot
        panel.prompt = L10n.t("settings.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.libraryError = library.changeRoot(to: url)
    }
}
