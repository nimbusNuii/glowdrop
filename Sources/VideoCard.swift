import AppKit
import SwiftUI

/// Shared card chrome: 16:9 thumbnail, title overlay, badge, hover and tap.
struct CardFrame<Thumb: View, Badge: View>: View {
    let title: String
    let subtitle: String?
    let isCurrent: Bool
    let action: () -> Void
    let accessibilityLabel: String
    let accessibilityHint: String
    @ViewBuilder let thumb: Thumb
    @ViewBuilder let badge: Badge
    @StateObject private var hover = HoverState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Color(white: 0.1)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { thumb }
                .overlay(alignment: .bottomLeading) { caption }
                .overlay(alignment: .topTrailing) { badge.padding(8) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.neon, lineWidth: isCurrent ? 2.5 : 0)
                }
                .shadow(color: .black.opacity(hover.isOn ? 0.6 : 0.3), radius: hover.isOn ? 14 : 6, y: 4)
                .shadow(color: Theme.neon.opacity(isCurrent ? 0.6 : 0), radius: 10)
                .scaleEffect(hover.isOn && !reduceMotion ? 1.03 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hover.isOn)
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityHint(Text(verbatim: accessibilityHint))
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.headline).foregroundColor(.white).lineLimit(1)
            if let subtitle {
                Text(verbatim: subtitle).font(.caption).foregroundColor(.white.opacity(0.7)).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .bottom, endPoint: .top))
    }
}

@MainActor
final class HoverState: ObservableObject {
    @Published var isOn = false
}

struct PlayingBadge: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Label { Text(verbatim: L10n.t("card.playing")) } icon: { Image(systemName: "play.fill") }
            .font(.caption.weight(.semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Theme.neon))
    }
}

private struct Badge4K: View {
    var body: some View {
        Text(verbatim: "4K")
            .font(.caption2.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(8)
    }
}

private struct Thumbnail: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "film").font(.largeTitle).foregroundColor(.secondary)
        }
    }
}

struct LibraryCard: View {
    @ObservedObject var library: VideoLibrary
    @EnvironmentObject private var settings: AppSettings
    let item: LibraryItem
    let subtitle: String?
    @StateObject private var loader = ThumbnailLoader()

    private var isCurrent: Bool { library.isCurrent(item) }

    private var cardLabel: String {
        [item.title, isCurrent ? L10n.t("card.playing") : nil, item.has4K ? L10n.t("card.has4K") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        CardFrame(title: item.title, subtitle: subtitle, isCurrent: isCurrent,
                  action: { library.select(item) },
                  accessibilityLabel: cardLabel, accessibilityHint: L10n.t("card.hint")) {
            Thumbnail(image: loader.image).overlay(alignment: .topLeading) { if item.has4K { Badge4K() } }
        } badge: {
            if isCurrent { PlayingBadge() }
        }
        .contextMenu {
            if let url = item.previewURL {
                Button(L10n.t("common.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        // The whole item (thumbnail included) is the id, so a thumb added or changed by a rescan reloads.
        .task(id: item) { await loader.load(image: item.thumbnail, video: item.previewURL) }
    }
}

struct UserFileCard: View {
    @ObservedObject var library: VideoLibrary
    @EnvironmentObject private var settings: AppSettings
    let url: URL
    @StateObject private var loader = ThumbnailLoader()

    private var isCurrent: Bool { library.currentPath == url.path }
    private var title: String { url.deletingPathExtension().lastPathComponent }
    /// A file the last scan could not find (e.g. its drive is gone): dimmed, never played, only removable.
    private var isMissing: Bool { library.missingUserFiles.contains(url) }

    var body: some View {
        CardFrame(title: title, subtitle: nil, isCurrent: isCurrent, action: select,
                  accessibilityLabel: title + (isCurrent ? ", " + L10n.t("card.playing") : ""),
                  accessibilityHint: isMissing ? L10n.f("library.error.missingFile", url.lastPathComponent)
                                               : L10n.t("card.hint")) {
            Thumbnail(image: loader.image)
        } badge: {
            if isCurrent { PlayingBadge() }
        }
        .opacity(isMissing ? 0.4 : 1)
        // Outside the card's own button, so this click removes instead of selecting.
        .overlay { if isMissing { Button(L10n.t("card.remove")) { library.removeUserFile(url) } } }
        .contextMenu {
            Button(L10n.t("common.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(L10n.t("card.remove")) { library.removeUserFile(url) }
        }
        .task(id: url) { await loader.load(image: nil, video: url) }
    }

    private func select() {
        if isMissing {
            library.showError("library.error.missingFile", url.lastPathComponent)
        } else {
            library.selectUserFile(url)
        }
    }
}
