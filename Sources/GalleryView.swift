import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case all, category(String), myVideos
}

// @State needs the SwiftUIMacros plugin, which the Command Line Tools toolchain lacks; use an object instead.
@MainActor
final class GalleryState: ObservableObject {
    @Published var selection: SidebarSelection? = .all
    @Published var search = ""
    @Published var isDropTargeted = false
}

struct GalleryView: View {
    @ObservedObject var library: VideoLibrary
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var state = GalleryState()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            GalleryDetail(library: library, state: state)
        }
        .frame(minWidth: 900, minHeight: 620)
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $state.isDropTargeted, perform: handleDrop)
        .overlay {
            if state.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.neon, style: StrokeStyle(lineWidth: 2.5, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $state.selection) {
            row(L10n.t("gallery.all"), icon: "square.grid.2x2").tag(SidebarSelection.all)
            if !library.categories.isEmpty {
                Section(L10n.t("gallery.categories")) {
                    ForEach(library.categories) { category in
                        row(L10n.categoryName(category.name), icon: "folder")
                            .tag(SidebarSelection.category(category.name))
                    }
                }
            }
            row(L10n.t("gallery.myVideos"), icon: "person.crop.rectangle").tag(SidebarSelection.myVideos)
        }
        .listStyle(.sidebar)
        .tint(Theme.neon)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    }

    private func row(_ title: String, icon: String) -> some View {
        Label { Text(verbatim: title) } icon: { Image(systemName: icon) }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { GalleryActions.addVideo(to: library) } label: {
                Label(L10n.t("gallery.addVideo"), systemImage: "plus")
            }
            Button { library.openLibraryFolder() } label: {
                Label(L10n.t("gallery.openLibraryFolder"), systemImage: "folder")
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { [library] url, error in
                Task { @MainActor in library.handleDropped(url, error: error) }
            }
        }
        return !providers.isEmpty
    }
}

@MainActor
enum GalleryActions {
    static func addVideo(to library: VideoLibrary) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = VideoLibrary.playableTypes
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.openFile(url)
    }
}
