import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, thai = "th", english = "en"
    var id: String { rawValue }
}

/// Who plays the wallpaper: Glowdrop's own desktop windows, or macOS through the bundled wallpaper extension.
enum WallpaperEngine: String, CaseIterable {
    case window, system
}

/// User preferences shared by the app, the wallpaper controller and the views; each change persists at once.
@MainActor
final class AppSettings: ObservableObject {
    static let defaultLibraryPath = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Glowdrop/Library", isDirectory: true).path

    private enum Key {
        static let language = "language", quality = "quality", libraryPath = "libraryPath"
        static let pauseWhenCovered = "pauseWhenCovered", pauseWhenLocked = "pauseWhenLocked"
        static let pauseInLowPowerMode = "pauseInLowPowerMode", pauseOnBattery = "pauseOnBattery"
        static let lockScreenSync = "lockScreenSync", engine = "wallpaperEngine"
    }

    @Published var language: AppLanguage {
        // willSet runs before @Published notifies, so subscribers already read the new language.
        willSet { L10n.use(newValue) }
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }
    @Published var quality: QualityPreference {
        didSet { defaults.set(quality.rawValue, forKey: Key.quality) }
    }
    @Published var pauseWhenCovered: Bool {
        didSet { defaults.set(pauseWhenCovered, forKey: Key.pauseWhenCovered) }
    }
    @Published var pauseWhenLocked: Bool {
        didSet { defaults.set(pauseWhenLocked, forKey: Key.pauseWhenLocked) }
    }
    @Published var pauseInLowPowerMode: Bool {
        didSet { defaults.set(pauseInLowPowerMode, forKey: Key.pauseInLowPowerMode) }
    }
    @Published var pauseOnBattery: Bool {
        didSet { defaults.set(pauseOnBattery, forKey: Key.pauseOnBattery) }
    }
    /// Mirror the wallpaper to the Lock Screen extension (macOS 26+). `bool(forKey:)` also reads a
    /// `-lockScreenSync YES` launch argument, which is not saved.
    @Published var lockScreenSync: Bool {
        didSet { defaults.set(lockScreenSync, forKey: Key.lockScreenSync) }
    }
    @Published var engine: WallpaperEngine {
        didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
    }
    /// Validated by `VideoLibrary.changeRoot(to:)` before it is set.
    @Published var libraryPath: String {
        didSet { defaults.set(libraryPath, forKey: Key.libraryPath) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        quality = defaults.string(forKey: Key.quality).flatMap(QualityPreference.init(rawValue:)) ?? .auto
        pauseWhenCovered = defaults.object(forKey: Key.pauseWhenCovered) as? Bool ?? true
        pauseWhenLocked = defaults.object(forKey: Key.pauseWhenLocked) as? Bool ?? true
        pauseInLowPowerMode = defaults.object(forKey: Key.pauseInLowPowerMode) as? Bool ?? true
        pauseOnBattery = defaults.object(forKey: Key.pauseOnBattery) as? Bool ?? false
        lockScreenSync = defaults.bool(forKey: Key.lockScreenSync)
        engine = defaults.string(forKey: Key.engine).flatMap(WallpaperEngine.init(rawValue:)) ?? .window
        libraryPath = defaults.string(forKey: Key.libraryPath) ?? Self.defaultLibraryPath
        L10n.use(language)
    }

    /// A saved `.system` on a macOS before 26 plays in the window.
    var usesSystemEngine: Bool {
        guard #available(macOS 26, *) else { return false }
        return engine == .system
    }
}
