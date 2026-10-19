import AppKit

/* Encodes are written to a scratch directory and copied out on Save; Copy
   hands the clipboard a copy named after the video. Whatever a crash leaves
   behind is swept at the next launch. */
enum TempFiles {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Lantern", isDirectory: true)
    /// Copy's files, a folder each so the file can carry the video's name.
    private static let copies = directory.appendingPathComponent("Copies", isDirectory: true)

    static func newEncodeURL() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Encode-\(UUID().uuidString).gif")
    }

    /// A fresh folder for the next Copy. Earlier copies go: this one takes
    /// their place on the clipboard, whichever window made them.
    static func newCopyFolder() -> URL {
        try? FileManager.default.removeItem(at: copies)
        let folder = copies.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /* Everything but the copy the clipboard still offers as a file, which
       can be pasted after Lantern quits (and after it launches again). */
    @MainActor
    static func sweep() {
        let onClipboard = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        sweep(directory, keeping: onClipboard)
    }

    static func sweep(_ directory: URL, keeping files: [URL]) {
        let manager = FileManager.default
        let copies = directory.appendingPathComponent(Self.copies.lastPathComponent, isDirectory: true)
        let kept = Set(files.map { canonical($0.deletingLastPathComponent()) })
        for item in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard item.lastPathComponent == copies.lastPathComponent else {
                remove(item)
                continue
            }
            for folder in (try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
            where !kept.contains(canonical(folder)) {
                remove(folder)
            }
        }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The temporary directory sits behind a symlink (/var → /private/var).
    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
