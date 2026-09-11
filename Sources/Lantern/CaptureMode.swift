import Foundation

/* What the toolbar is set to: a still or a recording, of a whole display, one
   window, or a dragged area — the six buttons of the system's ⌘⇧5 bar. */
enum CaptureKind: String, CaseIterable {
    case image, video
}

enum CaptureScope: String, CaseIterable {
    case display, window, area
}

struct CaptureMode: Equatable {
    var kind: CaptureKind
    var scope: CaptureScope

    /// "image.area" — the UserDefaults form.
    var stored: String { "\(kind.rawValue).\(scope.rawValue)" }

    init(kind: CaptureKind, scope: CaptureScope) {
        self.kind = kind
        self.scope = scope
    }

    init?(stored: String) {
        let parts = stored.split(separator: ".")
        guard parts.count == 2, let kind = CaptureKind(rawValue: String(parts[0])),
            let scope = CaptureScope(rawValue: String(parts[1]))
        else { return nil }
        self.init(kind: kind, scope: scope)
    }
}
