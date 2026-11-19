import SwiftUI

private enum GalleryEntry: Identifiable {
    case library(LibraryItem)
    case user(URL)

    var id: String {
        switch self {
        case .library(let item): return item.id
        case .user(let url): return "user:" + url.path
        }
    }

    var title: String {
        switch self {
        case .library(let item): return item.title
        case .user(let url): return url.deletingPathExtension().lastPathComponent
        }
    }
}

struct GalleryDetail: View {
    @ObservedObject var library: VideoLibrary
    @ObservedObject var state: GalleryState
    @EnvironmentObject private var settings: AppSettings

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 16)]
    private var selection: SidebarSelection { state.selection ?? .all }
    private var query: String { state.search.trimmingCharacters(in: .whitespaces) }

    private var sectionEntries: [GalleryEntry] {
        switch selection {
        case .all:
            return library.allItems.map(GalleryEntry.library) + library.userFiles.map(GalleryEntry.user)
        case .category(let name):
            return (library.categories.first { $0.name == name }?.items ?? []).map(GalleryEntry.library)
        case .myVideos:
            return library.userFiles.map(GalleryEntry.user)
        }
    }

    private var entries: [GalleryEntry] {
        query.isEmpty ? sectionEntries : sectionEntries.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var sectionTitle: String {
        switch selection {
        case .all: return L10n.t("gallery.all")
        case .category(let name): return L10n.categoryName(name)
        case .myVideos: return L10n.t("gallery.myVideos")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = library.bannerMessage { banner(message) }
            header
            ScrollView { content.padding(.vertical, 8) }
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.galleryBackground)
        .searchable(text: $state.search, prompt: Text(verbatim: L10n.t("gallery.search")))
        .onChange(of: library.categories) { categories in
            // The selected folder vanished in a rescan: fall back to All instead of an empty page.
            if case .category(let name) = selection, !categories.contains(where: { $0.name == name }) {
                state.selection = .all
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { GalleryActions.addVideo(to: library) } label: {
                    Label(L10n.t("gallery.addVideo"), systemImage: "plus")
                }
                .help(L10n.t("gallery.addVideo"))
                Button { library.rescan() } label: {
                    Label(L10n.t("common.refresh"), systemImage: "arrow.clockwise")
                }
                .help(L10n.t("common.refresh"))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: sectionTitle).font(.largeTitle.weight(.semibold))
            Text(verbatim: L10n.count(entries.count)).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        if sectionEntries.isEmpty {
            emptyState
        } else if entries.isEmpty {
            Text(verbatim: L10n.f("gallery.noResults", query))
                .font(.title3).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(entries) { entry in
                    switch entry {
                    case .library(let item):
                        LibraryCard(library: library, item: item,
                                    subtitle: selection == .all ? L10n.categoryName(item.category) : nil)
                    case .user(let url):
                        UserFileCard(library: library, url: url)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 44)).foregroundColor(.secondary)
            Text(verbatim: L10n.t("gallery.empty"))
                .font(.title3).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button(L10n.t("gallery.openLibraryFolder")) { library.openLibraryFolder() }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
            Text(verbatim: message).frame(maxWidth: .infinity, alignment: .leading)
            Button { library.dismissBanner() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: L10n.t("gallery.dismiss")))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)))
    }
}
