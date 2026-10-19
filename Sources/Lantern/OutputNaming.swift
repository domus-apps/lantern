import Foundation

/* A GIF is named after its video: "Screen Recording 2026-10-10 at 9.41.12.mov"
   becomes "Screen Recording 2026-10-10 at 9.41.12.gif", with " (2)", " (3)", …
   when that name is taken. */
enum OutputNaming {
    /// `base`.`ext`, with a counter appended while `exists` says the name is taken.
    static func fileName(base: String, ext: String, exists: (String) -> Bool = { _ in false }) -> String {
        var candidate = "\(base).\(ext)"
        var counter = 2
        while exists(candidate) {
            candidate = "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// A URL in `directory` that does not exist yet.
    static func uniqueURL(in directory: URL, base: String, ext: String) -> URL {
        let name = fileName(base: base, ext: ext) { candidate in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        return directory.appendingPathComponent(name)
    }
}
