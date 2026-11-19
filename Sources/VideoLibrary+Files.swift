import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// File-type checks and library-folder actions; they use only VideoLibrary's internal API.
extension VideoLibrary {
    /// Movie types AVFoundation can open; used for drops, Open With and the Add Video panel.
    static let playableTypes: [UTType] = AVURLAsset.audiovisualTypes()
        .compactMap { UTType($0.rawValue) }
        .filter { $0.conforms(to: .movie) }

    static func isVideoFile(_ url: URL) -> Bool {
        rejectionKey(for: url) == nil
    }

    /// nil for a movie AVFoundation can open; otherwise the message key saying why the file can't be used.
    static func rejectionKey(for url: URL) -> String? {
        guard url.isFileURL else { return "gallery.error.notVideo" }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return "gallery.error.notVideo" }
        if playableTypes.contains(type) { return nil }
        return type.conforms(to: .movie) ? "gallery.error.unsupportedFormat" : "gallery.error.notVideo"
    }

    // MARK: Files from outside the gallery

    /// Open With and drag-and-drop: library files apply directly, anything else joins "My Videos".
    func openFile(_ url: URL) {
        if isInLibrary(url) { apply(url) } else { addUserFile(url) }
    }

    func handleDropped(_ url: URL?, error: Error?) {
        if let error {
            showError("gallery.error.drop", error.localizedDescription)
        } else if let url {
            if let key = Self.rejectionKey(for: url) { showError(key, url.lastPathComponent) } else { openFile(url) }
        } else {
            showError("gallery.error.notVideo", "?")
        }
    }

    /// Only files the scanner would list count: depth ≤ 1 under a root, with a supported name.
    private func isInLibrary(_ url: URL) -> Bool {
        LibraryScanner.isLibraryFile(url, roots: [libraryRoot, Self.bundledRoot].compactMap { $0 })
    }

    /// Validates and switches the library folder; returns an error message when the folder is unusable.
    func changeRoot(to url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else { return L10n.t("library.error.notFolder") }
        settings.libraryPath = url.path
        rescan()
        return nil
    }

    func openLibraryFolder() {
        do {
            if settings.libraryPath == AppSettings.defaultLibraryPath {
                try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            }
        } catch {
            showError("library.error.folder", error.localizedDescription)
            return
        }
        // selectFile shows the folder in Finder and never launches it, even if it is a package such as X.app.
        if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: libraryRoot.path) {
            showError("library.error.folder", libraryRoot.path)
        }
    }
}
