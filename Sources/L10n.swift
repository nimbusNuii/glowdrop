import Foundation

/// A user-facing message stored as key + arguments, rendered at display time so it follows language changes.
struct LocalizedMessage: Equatable, Sendable {
    let key: String
    let args: [String]
}

/// Looks strings up in the `.lproj` picked in Settings, so a language change applies without a relaunch.
@MainActor
enum L10n {
    private static var bundle = Bundle.main

    static func use(_ language: AppLanguage) {
        let code = language == .system
            ? Bundle.preferredLocalizations(from: ["en", "th"]).first ?? "en"
            : language.rawValue
        bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    static func text(_ message: LocalizedMessage) -> String {
        String(format: t(message.key), arguments: message.args)
    }

    static func count(_ n: Int) -> String {
        n == 1 ? t("gallery.count.one") : f("gallery.count.other", n)
    }

    static func categoryName(_ name: String) -> String {
        name.isEmpty ? t("gallery.other") : name
    }
}
