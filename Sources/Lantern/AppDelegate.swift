import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/* A regular windowed app: it opens to the home window (where videos go),
   each video gets its own editor, and the home window comes back when the
   last editor closes. It keeps running with no windows, like Preview: the
   Dock icon still takes dropped videos, and clicking it brings the home
   window back. */
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let updater = UpdaterController()
    private var settingsWindowController: SettingsWindowController?
    private var homeWindowController: HomeWindowController?
    private var introWindowController: IntroWindowController?
    private var editors: [EditorWindowController] = []
    private var openedFilesAtLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        /* A translocated launch relaunches itself from the real bundle —
           nothing else must start in this doomed instance. */
        if TranslocationHealer.healIfNeeded() { return }

        TempFiles.sweep()
        setUpMainMenu()
        retireLoginItem()
        /* Finder's Services menu (Make GIF with Lantern) calls makeGIF. */
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        if DebugHooks.run(arguments: CommandLine.arguments, delegate: self) {
            return
        }

        /* A launch that came with files (Open With, a drop on the Dock icon)
           just opens them; otherwise show where videos go, or first, once
           after the update from 1.x, what Lantern does now. */
        if !openedFilesAtLaunch {
            if AppPreferences.cameFromCaptureApp {
                showIntro()
            } else {
                showHome()
            }
        }
        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TempFiles.sweep()
    }

    /* Open With, a drop on the Dock or Finder icon, `open -a Lantern x.mov`.
       At launch this arrives before applicationDidFinishLaunching. */
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFilesAtLaunch = true
        open(urls)
    }

    /* A Dock click with nothing on screen: bring back a minimized window
       (AppKit's default, hence true) or else the home window. */
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows || NSApp.windows.contains(where: \.isMiniaturized) {
            return true
        }
        showHome()
        return false
    }

    /* 1.x was a menu bar app with a Launch at Login switch. A windowed
       converter has no reason to start at login (it would greet every login
       with its window), so take the registration back once. */
    private func retireLoginItem() {
        guard Bundle.main.bundleIdentifier != nil, SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
    }

    // MARK: - Opening videos

    func open(_ urls: [URL]) {
        for url in urls {
            if let editor = editors.first(where: { $0.video.url.standardizedFileURL == url.standardizedFileURL }) {
                editor.present()
                continue
            }
            Task { @MainActor in
                do {
                    let video = try await SourceVideo.load(url)
                    openEditor(for: video)
                } catch {
                    Alerts.show(
                        title: L("“%@” can't be opened", url.lastPathComponent),
                        message: L("Lantern makes GIFs from videos, and this file has no video it can read."))
                    /* A launch whose only file failed would otherwise sit
                       in the Dock with no window. */
                    if !hasVisibleWindows {
                        showHome()
                    }
                }
            }
        }
    }

    func openEditor(for video: SourceVideo) {
        let editor = EditorWindowController(video: video)
        editor.onClose = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.editors.removeAll { $0 === editor }
            /* Back to the home window for the next video. */
            if self.editors.isEmpty {
                self.showHome()
            }
        }
        editors.append(editor)
        homeWindowController?.close()
        editor.present()
    }

    @objc private func chooseVideo() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.message = L("Choose a video to make a GIF from.")
        panel.prompt = L("Open")
        if panel.runModal() == .OK {
            open(panel.urls)
        }
    }

    /* ⌘V with a video copied in Finder. This sits at the end of the
       responder chain, so a focused text field (the editor's width) still
       pastes text first. */
    @objc func paste(_ sender: Any?) {
        open(VideoDrop.urls(from: .general))
    }

    /// NSServices entry point (Info.plist NSMessage "makeGIF").
    @objc func makeGIF(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = VideoDrop.urls(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = L("Lantern makes GIFs from videos, and this file has no video it can read.") as NSString
            return
        }
        open(urls)
    }

    private var hasVisibleWindows: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    private func showIntro() {
        let intro = IntroWindowController { [weak self] in
            AppPreferences.retireCaptureAppSettings()
            self?.introWindowController = nil
            if self?.editors.isEmpty == true {
                self?.showHome()
            }
        }
        introWindowController = intro
        intro.present()
    }

    private func showHome() {
        if homeWindowController == nil {
            homeWindowController = HomeWindowController(
                onOpen: { [weak self] urls in self?.open(urls) },
                onChoose: { [weak self] in self?.chooseVideo() })
        }
        NSApp.activate(ignoringOtherApps: true)
        homeWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menus

    private func setUpMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: L("About Lantern"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""))
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: L("Settings…"), action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(updater.makeMenuItem())
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: L("Services"))
        let services = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: L("Hide Lantern"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(
            title: L("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: L("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: L("Quit Lantern"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let fileMenu = NSMenu(title: L("File"))
        /* The home window, for the next video, even with editors open. */
        let newWindow = NSMenuItem(title: L("New Window"), action: #selector(newWindowAction), keyEquivalent: "n")
        newWindow.target = self
        fileMenu.addItem(newWindow)
        let open = NSMenuItem(title: L("Open Video…"), action: #selector(chooseVideo), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(
            title: L("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(NSMenuItem(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(NSMenuItem(
            title: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(
            title: L("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, editMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    /* Paste is offered only when the clipboard holds a video. */
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) {
            return !VideoDrop.urls(from: .general).isEmpty
        }
        return true
    }

    @objc private func newWindowAction() {
        showHome()
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(updater: updater)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}
