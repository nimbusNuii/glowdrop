import Foundation

/// The links the wallpaper tiles' right-click menu opens in the app. Any app or web page can open a glowdrop:// URL,
/// so a link is only ever one of these names: nothing else in the URL is read.
/// Foundation only: it is compiled into the app, the extension and the selftests.
enum GlowdropLink: String, CaseIterable, Sendable {
    case addVideo = "add-video", library

    private static let scheme = "glowdrop"

    /// `glowdrop://<rawValue>`. A fixed scheme and a host of lowercase letters and "-" always form a URL; the
    /// selftest builds and parses every case.
    var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = rawValue
        guard let url = parts.url else { preconditionFailure("glowdrop://\(rawValue) must form a URL") }
        return url
    }

    /// The whole URL string must be `glowdrop://<name>` or `glowdrop://<name>/`, in any letter case; anything more (a
    /// path, query, fragment, user, password, a port, even an empty one, or an escaped letter) is refused. URL maps a
    /// full-width host such as `ｌｉｂｒａｒｙ` to ASCII while parsing, so that form arrives as the plain name and passes.
    init?(url: URL) {
        let text = url.absoluteString.lowercased()
        let match = Self.allCases.first { [$0.url.absoluteString, $0.url.absoluteString + "/"].contains(text) }
        guard let match else { return nil }
        self = match
    }
}
