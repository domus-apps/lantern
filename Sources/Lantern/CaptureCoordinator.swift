import AppKit
import CoreMedia

/* The flow from shortcut to editor: toolbar + overlay to pick a target, then
   a still capture or a recording, then the editor window. One coordinator
   for the app; the status item reflects its state. */
@MainActor
final class CaptureCoordinator {
    enum State: Equatable {
        case idle
        case picking
        /// Seconds remaining before the capture starts.
        case countdown(Int)
        case recording
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    /// Elapsed recording time, twice a second while recording.
    var onRecordingTick: ((CMTime) -> Void)?
    /// Fires when the first editor opens and when the last one closes.
    var onEditorsChange: ((Bool) -> Void)?

    var hasOpenEditors: Bool { !editors.isEmpty }

    private var snapshot: ShareableSnapshot?
    private var toolbar: CaptureToolbarPanel?
    private var overlay: CaptureOverlayController?
    private var recorder: ScreenRecorder?
    private var recordingFrame: RecordingFrameWindow?
    private var tickTimer: Timer?
    private var countdownTimer: Timer?
    private var editors: [EditorWindowController] = []
    /* The app that was frontmost before the picker took over, to hand
       activation back to when it closes. */
    private var previousApp: NSRunningApplication?

    /// The shortcut: opens the picker, cancels it, or stops a recording.
    func toggle() {
        switch state {
        case .idle: begin()
        case .picking, .countdown: cancel()
        case .recording: stopRecording()
        }
    }

    func begin() {
        guard state == .idle else { return }
        guard PermissionGate.hasScreenRecording else {
            PermissionGate.request()
            return
        }
        state = .picking
        Task { @MainActor in
            do {
                let snapshot = try await ShareableSnapshot.fetch()
                guard state == .picking else { return }
                self.snapshot = snapshot
                showPicker(snapshot: snapshot)
            } catch {
                state = .idle
                Alerts.show(
                    title: L("Lantern can't see the screen"),
                    message: error.localizedDescription)
            }
        }
    }

    private func showPicker(snapshot: ShareableSnapshot) {
        let mode = AppPreferences.captureMode
        let overlay = CaptureOverlayController(snapshot: snapshot, mode: mode)
        let toolbar = CaptureToolbarPanel(mode: mode)
        overlay.onPick = { [weak self] target in self?.perform(target) }
        overlay.onCancel = { [weak self] in self?.cancel() }
        overlay.onReadinessChange = { [weak toolbar] ready in toolbar?.isPrimaryEnabled = ready }
        toolbar.onModeChange = { [weak overlay] mode in
            AppPreferences.captureMode = mode
            overlay?.mode = mode
        }
        toolbar.onPrimary = { [weak overlay] in overlay?.confirm() }
        toolbar.onCancel = { [weak self] in self?.cancel() }
        self.overlay = overlay
        self.toolbar = toolbar
        /* Cursor ownership: an inactive app's cursor changes are ignored
           until the pointer physically moves onto one of its windows, so an
           overlay appearing under a still pointer keeps the arrow. Becoming
           the active app makes the key overlay's cursor take effect at once;
           activation is handed back when the picker goes away. */
        if !NSApp.isActive {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp = front
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        overlay.show()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        toolbar.show(on: screen)
        toolbar.isPrimaryEnabled = overlay.isReady
    }

    func cancel() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        dismissPicker()
        if state != .recording { state = .idle }
    }

    private func dismissPicker() {
        toolbar?.close()
        overlay?.dismiss()
        toolbar = nil
        overlay = nil
        handBackActivation()
    }

    /* After the picker: the previous app comes back to the front (a still
       capture's editor re-activates Lantern right after; a recording leaves
       the user's app frontmost, as it should be). */
    private func handBackActivation() {
        let previous = previousApp
        previousApp = nil
        if let previous, !previous.isTerminated {
            previous.activate(from: .current, options: [])
        }
    }

    // MARK: - Capture

    private func perform(_ target: CaptureTarget) {
        guard let snapshot else { return }
        let mode = AppPreferences.captureMode
        dismissPicker()
        let delay = AppPreferences.timerSeconds
        if delay > 0 {
            runCountdown(from: delay) { [weak self] in
                self?.capture(target, kind: mode.kind, snapshot: snapshot)
            }
        } else {
            capture(target, kind: mode.kind, snapshot: snapshot)
        }
    }

    private func runCountdown(from seconds: Int, then action: @escaping () -> Void) {
        var remaining = seconds
        state = .countdown(remaining)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, case .countdown = self.state else {
                    timer.invalidate()
                    return
                }
                remaining -= 1
                if remaining <= 0 {
                    timer.invalidate()
                    self.countdownTimer = nil
                    action()
                } else {
                    self.state = .countdown(remaining)
                }
            }
        }
    }

    private func capture(_ target: CaptureTarget, kind: CaptureKind, snapshot: ShareableSnapshot) {
        switch kind {
        case .image:
            Task { @MainActor in
                do {
                    let image = try await StillCapturer.capture(
                        target, snapshot: snapshot, showsCursor: AppPreferences.showsCursor)
                    state = .idle
                    openEditor(.image(image))
                } catch {
                    state = .idle
                    Alerts.show(title: L("The screenshot failed"), message: error.localizedDescription)
                }
            }
        case .video:
            startRecording(target, snapshot: snapshot)
        }
    }

    // MARK: - Recording

    private func startRecording(_ target: CaptureTarget, snapshot: ShareableSnapshot) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            /* The frame goes up first, so the refreshed snapshot below finds
               Lantern among the apps with windows and the recorder's filter
               can exclude it, frame included. */
            if case .area(let display, let rect) = target,
                let screen = NSScreen.screens.first(where: {
                    snapshot.display(for: $0)?.displayID == display.displayID
                })
            {
                /* Back from display-local (top-left) to AppKit global. */
                let appKit = CGRect(
                    x: screen.frame.minX + rect.minX,
                    y: screen.frame.maxY - rect.maxY,
                    width: rect.width, height: rect.height)
                recordingFrame = RecordingFrameWindow(rect: appKit)
            }
            let snapshot = await snapshot.refreshingSelfApp()
            do {
                let recorder = try ScreenRecorder(
                    target: target, snapshot: snapshot, showsCursor: AppPreferences.showsCursor)
                recorder.onStoppedExternally = { [weak self] in self?.stopRecording() }
                self.recorder = recorder
                try await recorder.start()
                state = .recording
                tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let recorder = self.recorder else { return }
                        self.onRecordingTick?(recorder.elapsed)
                    }
                }
            } catch {
                recorder?.discard()
                recorder = nil
                recordingFrame?.close()
                recordingFrame = nil
                state = .idle
                Alerts.show(title: L("The recording couldn't start"), message: error.localizedDescription)
            }
        }
    }

    func stopRecording() {
        guard state == .recording, let recorder else { return }
        tickTimer?.invalidate()
        tickTimer = nil
        recordingFrame?.close()
        recordingFrame = nil
        self.recorder = nil
        state = .idle
        Task { @MainActor in
            do {
                let video = try await recorder.stop()
                openEditor(.video(video))
            } catch {
                recorder.discard()
                Alerts.show(title: L("The recording failed"), message: error.localizedDescription)
            }
        }
    }

    // MARK: - Editor

    /// For the --debug-editor hook only.
    func openEditorForDebugging(_ media: CapturedMedia) {
        openEditor(media)
    }

    /// For the --debug-record-ui hook only: the real recording path, frame
    /// and status item included, for an area of the main display.
    func startRecordingForDebugging(snapshot: ShareableSnapshot) {
        guard let display = snapshot.displays.first else { return }
        self.snapshot = snapshot
        startRecording(
            .area(display: display, rect: CGRect(x: 200, y: 200, width: 800, height: 500)),
            snapshot: snapshot)
    }

    private func openEditor(_ media: CapturedMedia) {
        let editor = EditorWindowController(media: media)
        editor.onClose = { [weak self, weak editor] in
            guard let self else { return }
            self.editors.removeAll { $0 === editor }
            if self.editors.isEmpty { self.onEditorsChange?(false) }
        }
        let first = editors.isEmpty
        editors.append(editor)
        if first { onEditorsChange?(true) }
        editor.present()
    }
}

/* Screen Recording is a launch-time permission: a grant while running only
   takes effect after a relaunch, which the onboarding window explains. */
enum PermissionGate {
    static let grantedAtLaunch = CGPreflightScreenCaptureAccess()

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts the first time (macOS shows its own dialog once); afterwards
    /// explains and offers the Settings pane.
    static func request() {
        if CGRequestScreenCaptureAccess() { return }
        let alert = NSAlert()
        alert.messageText = L("Lantern needs Screen Recording access")
        alert.informativeText = L("Allow Lantern under Privacy & Security › Screen & System Audio Recording, then open Lantern again.")
        alert.addButton(withTitle: L("Open Privacy & Security Settings…"))
        alert.addButton(withTitle: L("Later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSettingsPane()
        }
    }

    static func openSettingsPane() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

enum Alerts {
    @MainActor
    static func show(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
