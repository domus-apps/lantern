import Foundation
import LanternGIF

/* App-level preferences. Same UserDefaults caveat as the rest of the suite:
   `swift run` and the bundled app use different defaults domains. Every
   setter posts `changed`, which the Settings model listens to. */
enum AppPreferences {
    static let changed = Notification.Name("Lantern.PreferencesChanged")

    private static let defaults = UserDefaults.standard
    private static let saveLocationKey = "pref.gifSaveLocation"
    private static let saveFolderKey = "pref.saveFolder"
    private static let exportScaleKey = "pref.gifScale"
    private static let exportFPSKey = "pref.gifFPS"
    private static let qualityKey = "pref.gifQuality"
    private static let playbackKey = "pref.gifPlayback"
    private static let removesBorderKey = "pref.removeRecordingBorder"

    /* Keys only 1.x (the screen capture app) wrote. A Mac with any of them
       updated from 1.x and gets the intro to 2.0 once, after which they go.
       pref.saveFolder is shared with 2.0 and stays. */
    private static let captureAppKeys = [
        "onboarding.completed", "pref.hideMenuBarIcon", "pref.showsCursor", "pref.saveLocation",
        "pref.captureMode", "pref.timerSeconds", "pref.shortcut", "pref.exportScale", "pref.exportFPS",
        "pref.videoFormat",
    ]

    static var cameFromCaptureApp: Bool {
        captureAppKeys.contains { defaults.object(forKey: $0) != nil }
    }

    static func retireCaptureAppSettings() {
        for key in captureAppKeys { defaults.removeObject(forKey: key) }
    }

    /* Where GIFs land. Next to the video by default: that's the folder the
       user just dragged it from. `.folder` without a writable path, or a
       video in a folder Lantern can't write to, falls back to the Desktop,
       so Save never fails silently. (A new key: 1.x stored "desktop" as the
       default for screen captures.) */
    enum SaveLocation: String, CaseIterable {
        case source, desktop, folder, ask
    }

    static var saveLocation: SaveLocation {
        get { SaveLocation(rawValue: defaults.string(forKey: saveLocationKey) ?? "") ?? .source }
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
    static func resolvedSaveDirectory(forVideoAt video: URL) -> URL? {
        let writable = { (url: URL) in FileManager.default.isWritableFile(atPath: url.path) }
        switch saveLocation {
        case .ask: return nil
        case .desktop: return desktopDirectory
        case .source:
            let folder = video.deletingLastPathComponent()
            return writable(folder) ? folder : desktopDirectory
        case .folder:
            if let folder = saveFolder, writable(folder) { return folder }
            return desktopDirectory
        }
    }

    /* Editor defaults: the last-used size, frame rate, quality and playback
       come back next time. Half size by default, which is point size for a
       Retina screen recording. */
    static var exportScalePercent: Int {
        get { defaults.object(forKey: exportScaleKey) as? Int ?? 50 }
        set { set(newValue, forKey: exportScaleKey) }
    }

    static var exportFPS: Int {
        get { defaults.object(forKey: exportFPSKey) as? Int ?? 15 }
        set { set(newValue, forKey: exportFPSKey) }
    }

    static var quality: Int {
        get { defaults.object(forKey: qualityKey) as? Int ?? GIFEncoderOptions.defaultQuality }
        set { set(newValue, forKey: qualityKey) }
    }

    static var playback: Playback {
        get { Playback(rawValue: defaults.string(forKey: playbackKey) ?? "") ?? .loop }
        set { set(newValue.rawValue, forKey: playbackKey) }
    }

    /// Off until the user turns it on (it changes the picture).
    static var removesRecordingBorder: Bool {
        get { defaults.bool(forKey: removesBorderKey) }
        set { set(newValue, forKey: removesBorderKey) }
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
