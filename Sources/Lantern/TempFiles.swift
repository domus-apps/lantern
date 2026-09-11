import Foundation

/* Recordings are written to a scratch directory and only copied out when
   the user exports. Whatever a crash leaves behind is swept at the next
   launch; there is no recovery UI. */
enum TempFiles {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Lantern", isDirectory: true)

    static func newRecordingURL() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Recording-\(UUID().uuidString).mp4")
    }

    static func newExportURL(ext: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Export-\(UUID().uuidString).\(ext)")
    }

    static func sweep() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
