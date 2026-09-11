import AppKit
import CoreMedia

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updater = UpdaterController()
    private let hotKeys = HotKeyCenter()
    private let coordinator = CaptureCoordinator()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?

    private static let onboardingCompletedKey = "onboarding.completed"

    func applicationDidFinishLaunching(_ notification: Notification) {
        /* A translocated launch relaunches itself from the real bundle —
           nothing else must start in this doomed instance. */
        if TranslocationHealer.healIfNeeded() { return }

        TempFiles.sweep()
        setUpMainMenu()
        observePreferenceChanges()
        updateStatusItemVisibility()
        registerShortcut()

        coordinator.onStateChange = { [weak self] _ in self?.updateStatusIcon() }
        coordinator.onRecordingTick = { [weak self] elapsed in self?.showElapsed(elapsed) }
        coordinator.onEditorsChange = { [weak self] _ in
            /* The closing editor is still visible inside willClose; decide
               on the next runloop turn. */
            DispatchQueue.main.async {
                self?.updateActivationPolicy()
                self?.handBackActivationIfWindowless()
            }
        }

        if DebugHooks.run(arguments: CommandLine.arguments, coordinator: coordinator) {
            return
        }

        /* Completion is only recorded when onboarding is finished properly,
           so an interrupted (or force-quit) run shows it again. The gate also
           returns whenever the permission is missing at launch. */
        if !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
            || !PermissionGate.grantedAtLaunch
            || CommandLine.arguments.contains("--onboarding")
        {
            showOnboarding()
        }
        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }
        if CommandLine.arguments.contains("--capture") {
            coordinator.begin()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TempFiles.sweep()
    }

    private func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
                self?.onboardingController = nil
            }
            observeClose(of: onboardingController?.window)
        }
        comeForward()
        onboardingController?.window?.makeKeyAndOrderFront(nil)
    }

    /* Launching the app again while it's already running sends "reopen" to
       the live instance. With the menu bar icon hidden this is the only way
       back into the UI, so surface Settings (which also puts the app in the
       Dock via updateActivationPolicy). */
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if AppPreferences.isMenuBarIconHidden {
            openSettings()
        }
        return false
    }

    // MARK: - Shortcut

    private func registerShortcut() {
        hotKeys.unregisterAll()
        let spec = AppPreferences.shortcut
        hotKeys.register(keyCode: spec.keyCode, modifiers: spec.carbonModifiers) { [weak self] in
            self?.coordinator.toggle()
        }
        if let item = statusMenu?.item(withTag: Self.captureItemTag) {
            applyKeyEquivalent(spec, to: item)
        }
    }

    private func applyKeyEquivalent(_ spec: ShortcutSpec, to item: NSMenuItem) {
        if let equivalent = spec.menuKeyEquivalent {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.mask
        } else {
            item.keyEquivalent = ""
        }
    }

    // MARK: - Status item

    private static let captureItemTag = 1

    private func updateStatusItemVisibility() {
        if AppPreferences.isMenuBarIconHidden {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            statusMenu = nil
        } else if statusItem == nil {
            setUpStatusItem()
        }
        updateActivationPolicy()
    }

    private func setUpStatusItem() {
        /* A fixed length instead of squareLength: square items are as wide
           as the menu bar is tall, which pads a ~18pt symbol with a lot of
           dead space. 20pt hugs the icon while keeping its natural size —
           the same width every Domus app uses. */
        let item = NSStatusBar.system.statusItem(withLength: 20)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)

        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "Lantern \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())
        let capture = NSMenuItem(title: L("Capture…"), action: #selector(beginCapture), keyEquivalent: "")
        capture.target = self
        capture.tag = Self.captureItemTag
        applyKeyEquivalent(AppPreferences.shortcut, to: capture)
        menu.addItem(capture)
        menu.addItem(.separator())
        let onboardingItem = NSMenuItem(
            title: L("Show Welcome Guide…"), action: #selector(reopenOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(updater.makeMenuItem())
        /* Remote-debugging aid: one click copies the permission state and
           what ScreenCaptureKit can see, for pasting back. */
        let diagnostics = NSMenuItem(title: L("Copy Diagnostics"), action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: L("Quit Lantern"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusMenu = menu
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    /* Idle: the lantern, with the menu. Recording: a stop button with the
       elapsed time, and a single click stops (the system tool works the same
       way). Countdown: the seconds left. */
    private func updateStatusIcon() {
        guard let statusItem, let button = statusItem.button else { return }
        switch coordinator.state {
        case .idle, .picking:
            button.image = MenuBarIcon.lantern()
            button.contentTintColor = nil
            button.title = ""
            /* imageOnly, or the empty title still reserves room and pushes
               the glyph off center in the 20pt item. */
            button.imagePosition = .imageOnly
            statusItem.length = 20
            statusItem.menu = statusMenu
        case .countdown(let seconds):
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: L("Capturing soon"))
            button.contentTintColor = nil
            button.imagePosition = .imageLeading
            button.title = " \(seconds)"
            statusItem.length = NSStatusItem.variableLength
            statusItem.menu = nil
        case .recording:
            button.image = MenuBarIcon.recording()
            button.contentTintColor = nil
            button.imagePosition = .imageLeading
            button.title = " 0:00"
            statusItem.length = NSStatusItem.variableLength
            statusItem.menu = nil
        }
    }

    private func showElapsed(_ elapsed: CMTime) {
        guard case .recording = coordinator.state else { return }
        let seconds = max(Int(elapsed.seconds.rounded(.down)), 0)
        statusItem?.button?.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func statusItemClicked() {
        switch coordinator.state {
        case .recording: coordinator.stopRecording()
        case .countdown: coordinator.cancel()
        default: break
        }
    }

    @objc private func beginCapture() {
        coordinator.begin()
    }

    @objc private func reopenOnboarding() {
        showOnboarding()
    }

    @objc private func copyDiagnostics() {
        Task { @MainActor in
            let report = await Diagnostics.report()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    // MARK: - Menus & windows

    /* An accessory app has no visible menu bar, but ⌘-key equivalents are
       still dispatched through the main menu — without one, ⌘W/⌘Q do
       nothing in the settings or editor windows. */
    private func setUpMainMenu() {
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: L("Settings…"), action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(updater.makeMenuItem())
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: L("Quit Lantern"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(NSMenuItem(
            title: L("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(
            title: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    private func observePreferenceChanges() {
        NotificationCenter.default.addObserver(
            forName: AppPreferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusItemVisibility()
                self?.registerShortcut()
            }
        }
    }

    private var isSettingsWindowVisible: Bool {
        settingsWindowController?.window?.isVisible == true
    }

    /* Activation hand-back. An accessory app that activates itself to show
       a window stays the active app after that window closes — macOS never
       moves activation on window close — so a windowless Lantern would be
       left frontmost until the user clicked elsewhere. Remember who was
       active before we came forward and give activation back once our last
       window is gone. */
    private var previouslyActiveApp: NSRunningApplication?

    private func comeForward() {
        if !NSApp.isActive,
            let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            previouslyActiveApp = front
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handBackActivationIfWindowless() {
        guard NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let previous = previouslyActiveApp
        previouslyActiveApp = nil
        if let previous, !previous.isTerminated, previous.activate(from: .current, options: []) {
            return
        }
        /* No one to hand back to (quit meanwhile): hiding yields activation
           to whatever the system picks next. */
        NSApp.hide(nil)
    }

    private func observeClose(of window: NSWindow?) {
        guard let window else { return }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            /* isVisible is still true inside willClose; re-evaluate (leave the
               Dock, hand activation back) on the next runloop cycle. */
            DispatchQueue.main.async {
                self?.updateActivationPolicy()
                self?.handBackActivationIfWindowless()
            }
        }
    }

    /* Dock presence: the app normally stays invisible (accessory policy).
       It joins the Dock while an editor is open, so the capture you are
       working on is reachable through ⌘-Tab and window switchers like any
       document window, and while the menu bar icon is hidden AND Settings
       is open, when there would otherwise be no sign the app is running.
       It leaves again when those windows close. */
    private func updateActivationPolicy() {
        let wantsDock = coordinator.hasOpenEditors
            || (AppPreferences.isMenuBarIconHidden && isSettingsWindowVisible)
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        /* Flipping the policy can drop activation; keep the front window in
           front. */
        if wantsDock {
            NSApp.activate(ignoringOtherApps: true)
            (NSApp.keyWindow ?? settingsWindowController?.window)?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(updater: updater)
            observeClose(of: settingsWindowController?.window)
        }
        /* Accessory apps don't come forward on their own — activate first or
           the window opens behind the current app. */
        comeForward()
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
    }
}

/* One-shot report for remote debugging, copied by the status menu item. */
enum Diagnostics {
    static func report() async -> String {
        var lines = ["Lantern diagnostics"]
        let info = Bundle.main.infoDictionary
        lines.append(
            "version: \(info?["CFBundleShortVersionString"] as? String ?? "dev")"
                + " (\(info?["CFBundleVersion"] as? String ?? "-"))")
        lines.append("screen recording preflight: \(PermissionGate.hasScreenRecording)")
        lines.append("granted at launch: \(PermissionGate.grantedAtLaunch)")
        lines.append("shortcut: \(AppPreferences.shortcut.displayString)")
        lines.append("save location: \(AppPreferences.saveLocation.rawValue) \(AppPreferences.resolvedSaveDirectory?.path ?? "ask")")
        for screen in NSScreen.screens {
            lines.append("screen: \(screen.localizedName) \(NSStringFromRect(screen.frame)) @\(screen.backingScaleFactor)x")
        }
        do {
            let snapshot = try await ShareableSnapshot.fetch()
            lines.append("SCShareableContent: \(snapshot.displays.count) displays, \(snapshot.windows.count) windows, self \(snapshot.selfApp != nil ? "found" : "missing")")
        } catch {
            lines.append("SCShareableContent: FAILED \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
