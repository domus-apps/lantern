import Foundation

/* App-level preferences. Same UserDefaults caveat as the rest of the suite:
   `swift run` and the bundled app use different defaults domains. Every
   setter posts `changed`, which the status item, the hotkey registration,
   and the Settings model all listen to. */
enum AppPreferences {
    static let changed = Notification.Name("Lantern.PreferencesChanged")

    private static let defaults = UserDefaults.standard
    private static let hideMenuBarIconKey = "pref.hideMenuBarIcon"
    private static let showsCursorKey = "pref.showsCursor"
    private static let saveLocationKey = "pref.saveLocation"
    private static let saveFolderKey = "pref.saveFolder"
    private static let captureModeKey = "pref.captureMode"
    private static let timerSecondsKey = "pref.timerSeconds"
    private static let shortcutKey = "pref.shortcut"
    private static let exportScaleKey = "pref.exportScale"
    private static let exportFPSKey = "pref.exportFPS"
    private static let videoFormatKey = "pref.videoFormat"

    static var isMenuBarIconHidden: Bool {
        get { defaults.bool(forKey: hideMenuBarIconKey) }
        set { set(newValue, forKey: hideMenuBarIconKey) }
    }

    /* On by default, like the system tool's "Show Mouse Pointer". */
    static var showsCursor: Bool {
        get { defaults.object(forKey: showsCursorKey) as? Bool ?? true }
        set { set(newValue, forKey: showsCursorKey) }
    }

    /* Where exports land. `.folder` without a readable path falls back to
       the Desktop, so a moved folder never makes Save fail silently. */
    enum SaveLocation: String, CaseIterable {
        case desktop, folder, ask
    }

    static var saveLocation: SaveLocation {
        get { SaveLocation(rawValue: defaults.string(forKey: saveLocationKey) ?? "") ?? .desktop }
        set { set(newValue.rawValue, forKey: saveLocationKey) }
    }

    static var saveFolder: URL? {
        get { defaults.string(forKey: saveFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { set(newValue?.path, forKey: saveFolderKey) }
    }

    static var desktopDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// The directory Save writes to without asking; nil means "ask".
    static var resolvedSaveDirectory: URL? {
        switch saveLocation {
        case .desktop: return desktopDirectory
        case .ask: return nil
        case .folder:
            if let folder = saveFolder, FileManager.default.isWritableFile(atPath: folder.path) {
                return folder
            }
            return desktopDirectory
        }
    }

    /* The toolbar's selected mode, remembered like the system tool does. */
    static var captureMode: CaptureMode {
        get { CaptureMode(stored: defaults.string(forKey: captureModeKey) ?? "") ?? .init(kind: .image, scope: .area) }
        set { set(newValue.stored, forKey: captureModeKey) }
    }

    /* 0 means no delay. */
    static var timerSeconds: Int {
        get { defaults.integer(forKey: timerSecondsKey) }
        set { set(newValue, forKey: timerSecondsKey) }
    }

    static var shortcut: ShortcutSpec {
        get {
            guard let data = defaults.data(forKey: shortcutKey),
                let spec = try? JSONDecoder().decode(ShortcutSpec.self, from: data)
            else { return .defaultCapture }
            return spec
        }
        set { set(try? JSONEncoder().encode(newValue), forKey: shortcutKey) }
    }

    /* Editor defaults: the last-used size and frame rate come back next time. */
    static var exportScalePercent: Int {
        get { defaults.object(forKey: exportScaleKey) as? Int ?? 100 }
        set { set(newValue, forKey: exportScaleKey) }
    }

    static var exportFPS: Int {
        get { defaults.object(forKey: exportFPSKey) as? Int ?? 60 }
        set { set(newValue, forKey: exportFPSKey) }
    }

    static var videoFormat: ExportFormat {
        get { ExportFormat(rawValue: defaults.string(forKey: videoFormatKey) ?? "") ?? .mp4 }
        set { set(newValue.rawValue, forKey: videoFormatKey) }
    }

    private static func set(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
