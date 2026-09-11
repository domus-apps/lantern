import AppKit

/* First-run onboarding: what Lantern is, the shortcut, and the Screen
   Recording permission gate. The window has no close button and refuses
   every close attempt; the only way out is granting access and clicking
   Start, and completion is persisted only at that click, so quitting
   mid-onboarding brings it back on the next launch.

   Screen Recording only takes effect at process launch: a grant made while
   Lantern is running needs a relaunch, and comparing against the state at
   launch is what tells the two cases apart. */
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onComplete: () -> Void
    private var pollTimer: Timer?

    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var requestButton = NSButton(
        title: L("Allow Screen Recording…"), target: self, action: #selector(requestAccess))
    private lazy var settingsLink = NSButton(
        title: L("Open Privacy & Security Settings…"), target: self, action: #selector(openSystemSettings))
    private lazy var relaunchButton = NSButton(
        title: L("Relaunch Lantern"), target: self, action: #selector(relaunch))
    private lazy var startButton = NSButton(
        title: L("Start Using Lantern"), target: self, action: #selector(start))

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        /* No .closable: the traffic-light close button never appears. */
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()

        refreshPermissionState()
        /* Permission grants don't notify; polling once a second is the
           standard idiom (the System Settings toggle takes effect live). */
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPermissionState()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /* The gate: no closing until onboarding is completed via start(). */
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    // MARK: - Content

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: L("Welcome to Lantern"))
        title.font = .systemFont(ofSize: 30, weight: .bold)

        let intro = NSTextField(
            wrappingLabelWithString: L("Lantern captures the screen as an image or a recording: a whole display, one window, or the area you drag. Afterwards you pick the size, the frame rate, and PNG, MP4, or GIF."))
        intro.font = .systemFont(ofSize: 14)
        intro.textColor = .secondaryLabelColor
        intro.alignment = .center
        intro.preferredMaxLayoutWidth = 470

        let illustration = OnboardingIllustrationView()
        illustration.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            illustration.widthAnchor.constraint(equalToConstant: 480),
            illustration.heightAnchor.constraint(equalToConstant: 190),
        ])

        var shortcutViews: [NSView] = [labelView(L("Press"))]
        for symbol in AppPreferences.shortcut.displayString.map(String.init) {
            shortcutViews.append(KeycapView(symbol: symbol))
        }
        shortcutViews.append(labelView(L("to open the capture bar")))
        let shortcutRow = NSStackView(views: shortcutViews)
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 6

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.alignment = .center
        requestButton.bezelStyle = .rounded
        requestButton.keyEquivalent = "\r"
        settingsLink.isBordered = false
        settingsLink.contentTintColor = .linkColor
        settingsLink.font = .systemFont(ofSize: 12)
        relaunchButton.bezelStyle = .rounded

        let permissionBox = NSStackView(views: [statusLabel, requestButton, settingsLink, relaunchButton])
        permissionBox.orientation = .vertical
        permissionBox.alignment = .centerX
        permissionBox.spacing = 8

        startButton.bezelStyle = .rounded
        startButton.controlSize = .large

        let stack = NSStackView(views: [title, intro, illustration, shortcutRow, permissionBox, startButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(10, after: title)
        stack.setCustomSpacing(22, after: intro)
        stack.setCustomSpacing(24, after: shortcutRow)
        stack.setCustomSpacing(20, after: permissionBox)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
        ])
        return container
    }

    private func labelView(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Permission gate

    private func refreshPermissionState() {
        let granted = PermissionGate.hasScreenRecording
        let usable = granted && PermissionGate.grantedAtLaunch
        if usable {
            statusLabel.stringValue = L("✓ Screen Recording access granted")
            statusLabel.textColor = .systemGreen
        } else if granted {
            statusLabel.stringValue = L("✓ Screen Recording granted. Relaunch Lantern to start capturing.")
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = L("Lantern needs Screen Recording access to capture the screen.")
            statusLabel.textColor = .labelColor
        }
        requestButton.isHidden = granted
        settingsLink.isHidden = granted
        /* A bare `swift run` binary can't relaunch itself by bundle. */
        relaunchButton.isHidden = usable || !granted || Bundle.main.bundleIdentifier == nil
        startButton.isEnabled = usable
        startButton.keyEquivalent = usable ? "\r" : ""
    }

    @objc private func requestAccess() {
        /* The system prompt appears only on the very first ask; afterwards
           macOS stays silent, so the settings link below is the fallback. */
        if !CGRequestScreenCaptureAccess() {
            PermissionGate.openSettingsPane()
        }
        refreshPermissionState()
    }

    @objc private func openSystemSettings() {
        PermissionGate.openSettingsPane()
    }

    @objc private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc private func start() {
        guard PermissionGate.hasScreenRecording else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        window?.delegate = nil
        onComplete()
        close()
    }
}

/* One keyboard key, drawn as a keycap. */
private final class KeycapView: NSView {
    private let symbol: String

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.quaternarySystemFill.setFill()
        body.fill()
        NSColor.separatorColor.setStroke()
        body.lineWidth = 1
        body.stroke()

        let text = NSAttributedString(
            string: symbol,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/* A drawn "screenshot" of Lantern in action: a dimmed desktop with a
   selection cut out of it, handles at the corners, and the capture bar at
   the bottom. Drawn (not a bundled image) so it stays crisp at any backing
   scale and needs no resource plumbing. */
private final class OnboardingIllustrationView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let canvas = bounds

        // Desktop backdrop in Lantern's deep red
        let backdrop = NSBezierPath(roundedRect: canvas, xRadius: 12, yRadius: 12)
        NSGradient(
            starting: NSColor(srgbRed: 0.30, green: 0.10, blue: 0.12, alpha: 1),
            ending: NSColor(srgbRed: 0.14, green: 0.04, blue: 0.05, alpha: 1)
        )?.draw(in: backdrop, angle: -90)

        // Two "windows" on the desktop
        for (rect, alpha) in [
            (NSRect(x: 36, y: 78, width: 210, height: 96), 0.18),
            (NSRect(x: 270, y: 60, width: 176, height: 118), 0.14),
        ] {
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }

        // Dim, with the selection cut out
        let selection = NSRect(x: 120, y: 66, width: 236, height: 104)
        let dim = NSBezierPath(roundedRect: canvas, xRadius: 12, yRadius: 12)
        dim.appendRect(selection)
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1
        border.stroke()
        for corner in [
            NSPoint(x: selection.minX, y: selection.minY), NSPoint(x: selection.maxX, y: selection.minY),
            NSPoint(x: selection.maxX, y: selection.maxY), NSPoint(x: selection.minX, y: selection.maxY),
        ] {
            let handle = NSRect(x: corner.x - 3.5, y: corner.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handle).fill()
        }

        // The capture bar
        let bar = NSRect(x: canvas.midX - 150, y: 14, width: 300, height: 34)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        var x = bar.minX + 12
        let symbols = ["inset.filled.rectangle", "macwindow", "rectangle.dashed"]
        for (index, name) in symbols.enumerated() {
            let selected = index == 2
            if selected {
                NSColor.black.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: NSRect(x: x - 4, y: bar.midY - 11, width: 26, height: 22), xRadius: 5, yRadius: 5).fill()
            }
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            image?.draw(in: NSRect(x: x, y: bar.midY - 7, width: 18, height: 14))
            x += 30
        }
        let button = NSRect(x: bar.maxX - 74, y: bar.midY - 10, width: 62, height: 20)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: button, xRadius: 5, yRadius: 5).fill()
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let accentIsLight = accent.map {
            0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent > 0.7
        } ?? false
        let label = NSAttributedString(
            string: L("Capture"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: accentIsLight ? NSColor.black : NSColor.white,
            ])
        let labelSize = label.size()
        label.draw(at: NSPoint(x: button.midX - labelSize.width / 2, y: button.midY - labelSize.height / 2))
    }
}
