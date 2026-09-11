import Foundation

/* System-style file names: "Screenshot 2026-09-10 at 10.41.32.png",
   "Screen Recording 2026-09-10 at 10.41.32.mp4". The timestamp format is
   fixed (the system's varies by locale) so names sort and test predictably;
   the two prefixes follow the UI language. */
enum OutputNaming {
    enum Kind {
        case screenshot, recording

        var prefix: String {
            switch self {
            case .screenshot: L("Screenshot")
            case .recording: L("Screen Recording")
            }
        }
    }

    /* A formatter per call: a shared one whose time zone is set per call is
       a race (DateFormatter isn't thread-safe), which the parallel test
       runner exposed on a UTC machine. */
    private static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        formatter.timeZone = timeZone
        return formatter
    }

    /// The name for `date`, with " (2)", " (3)", … appended while `exists`
    /// says the name is taken.
    static func fileName(
        kind: Kind, date: Date, ext: String, timeZone: TimeZone = .current,
        exists: (String) -> Bool = { _ in false }
    ) -> String {
        let base = "\(kind.prefix) \(formatter(timeZone).string(from: date))"
        var candidate = "\(base).\(ext)"
        var counter = 2
        while exists(candidate) {
            candidate = "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// A URL in `directory` that does not exist yet.
    static func uniqueURL(in directory: URL, kind: Kind, ext: String, date: Date = Date()) -> URL {
        let name = fileName(kind: kind, date: date, ext: ext) { candidate in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        return directory.appendingPathComponent(name)
    }
}
