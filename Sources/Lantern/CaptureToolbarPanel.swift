import AppKit

/* The ⌘⇧5-style bar at the bottom of the screen: close, three still modes,
   three recording modes, Options, and the Capture / Record button. Glass
   card on a nonactivating panel above the overlay; it never takes key
   status (the overlay handles Return and Escape), so clicks work while the
   frontmost app stays frontmost. */
@MainActor
final class CaptureToolbarPanel {
    var onModeChange: ((CaptureMode) -> Void)?
    var onPrimary: (() -> Void)?
    var onCancel: (() -> Void)?

    private let panel: NSPanel
    private let imageSegments: ModeGroupControl
    private let videoSegments: ModeGroupControl
    private let primaryButton: NSButton
    private let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private static let cornerRadius: CGFloat = 16
    private static let shadowMargin: CGFloat = 40

    private(set) var mode: CaptureMode {
        didSet { reflectMode() }
    }

    var isPrimaryEnabled: Bool {
        get { primaryButton.isEnabled }
        set { primaryButton.isEnabled = newValue }
    }

    init(mode: CaptureMode) {
        self.mode = mode
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 60 + Self.shadowMargin * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        /* Draggable by its glass, like a HUD; the transparent shadow margin
           is click-through, so only the card itself grabs. */
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.level = CaptureLevels.toolbar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let scopes: [(CaptureScope, String, String)] = [
            (.display, "inset.filled.rectangle", L("Entire Screen")),
            (.window, "macwindow", L("Selected Window")),
            (.area, "rectangle.dashed", L("Selected Portion")),
        ]
        imageSegments = ModeGroupControl(
            images: scopes.map { NSImage.labelTinted($0.1, pointSize: 15) ?? NSImage() },
            toolTips: scopes.map { L("Capture %@", $0.2) })
        videoSegments = ModeGroupControl(
            images: scopes.map { NSImage.recordBadged($0.1, pointSize: 15) ?? NSImage() },
            toolTips: scopes.map { L("Record %@", $0.2) })
        primaryButton = NSButton(title: L("Capture"), target: nil, action: nil)

        buildContent()
        reflectMode()
    }

    private func buildContent() {
        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Close"))?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) ?? NSImage(),
            target: self, action: #selector(closeClicked))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = L("Close")
        closeButton.setAccessibilityLabel(L("Close"))
        /* A borderless image button reports no intrinsic width inside this
           stack (it laid out at 0pt wide), so size it explicitly. */
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        imageSegments.onSelect = { [weak self] index in
            guard let self else { return }
            self.mode = CaptureMode(kind: .image, scope: CaptureScope.allCases[index])
            self.onModeChange?(self.mode)
        }
        videoSegments.onSelect = { [weak self] index in
            guard let self else { return }
            self.mode = CaptureMode(kind: .video, scope: CaptureScope.allCases[index])
            self.onModeChange?(self.mode)
        }
        imageSegments.setAccessibilityLabel(L("Capture"))
        videoSegments.setAccessibilityLabel(L("Record"))

        optionsButton.controlSize = .large
        optionsButton.bezelStyle = .rounded
        optionsButton.menu = makeOptionsMenu()
        optionsButton.setAccessibilityLabel(L("Options"))

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        /* The title switches between Capture and Record; size the button
           for the wider one so the bar's right end never moves. */
        let widest = [L("Capture"), L("Record")].map { title -> CGFloat in
            primaryButton.title = title
            return primaryButton.fittingSize.width
        }.max() ?? 0
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.widthAnchor.constraint(equalToConstant: widest).isActive = true

        let stack = NSStackView(views: [
            closeButton, imageSegments, videoSegments, optionsButton, primaryButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        /* One rhythm throughout: 12pt between every control and at both
           ends. */
        stack.spacing = 12
        /* Every control here draws exactly its frame, except the close glyph,
           a 16pt circle inside its 22pt box; its two gaps give those 3pt
           back so every visible gap, both ends included, is 12pt. */
        stack.setCustomSpacing(9, after: closeButton)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10.5, bottom: 10, right: 13)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = ArrowCursorView()
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        let size = stack.fittingSize
        let glassFrame = NSRect(x: Self.shadowMargin, y: Self.shadowMargin, width: size.width, height: size.height)
        content.frame = glassFrame

        let shadow = MenuShadowView(frame: glassFrame, cornerRadius: Self.cornerRadius)
        let glass = NSGlassEffectView(frame: glassFrame)
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = content
        let hairline = HairlineBorderView(frame: glassFrame, cornerRadius: Self.cornerRadius)

        let root = NSView(frame: NSRect(
            x: 0, y: 0,
            width: size.width + Self.shadowMargin * 2, height: size.height + Self.shadowMargin * 2))
        for view in [shadow, glass, hairline] {
            root.addSubview(view)
        }
        panel.setContentSize(root.frame.size)
        panel.contentView = root
    }

    private func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        /* Pull-down buttons show their first item as the title. */
        menu.addItem(NSMenuItem(title: L("Options"), action: nil, keyEquivalent: ""))

        let cursor = NSMenuItem(title: L("Show Mouse Pointer"), action: #selector(toggleCursor), keyEquivalent: "")
        cursor.target = self
        cursor.state = AppPreferences.showsCursor ? .on : .off
        menu.addItem(cursor)
        menu.addItem(.separator())

        let saveHeader = NSMenuItem(title: L("Save to"), action: nil, keyEquivalent: "")
        saveHeader.isEnabled = false
        menu.addItem(saveHeader)
        for (location, title) in [
            (AppPreferences.SaveLocation.desktop, L("Desktop")),
            (.folder, AppPreferences.saveFolder.map { L("Folder: %@", $0.lastPathComponent) } ?? L("Other Folder…")),
            (.ask, L("Ask Where to Save")),
        ] {
            let item = NSMenuItem(title: title, action: #selector(saveLocationChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = location.rawValue
            item.state = AppPreferences.saveLocation == location ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let timerHeader = NSMenuItem(title: L("Timer"), action: nil, keyEquivalent: "")
        timerHeader.isEnabled = false
        menu.addItem(timerHeader)
        for (seconds, title) in [(0, L("None")), (5, L("5 Seconds")), (10, L("10 Seconds"))] {
            let item = NSMenuItem(title: title, action: #selector(timerChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = AppPreferences.timerSeconds == seconds ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
        return menu
    }

    private func reflectMode() {
        let index = CaptureScope.allCases.firstIndex(of: mode.scope) ?? 0
        imageSegments.selectedIndex = mode.kind == .image ? index : nil
        videoSegments.selectedIndex = mode.kind == .video ? index : nil
        primaryButton.title = mode.kind == .image ? L("Capture") : L("Record")
    }

    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode else { return }
        mode = newMode
    }

    // MARK: - Showing

    /// Bottom-center of `screen`, just above the Dock area.
    func show(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: visible.minY + 24 - Self.shadowMargin)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CaptureOverlayController.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        let panel = self.panel
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = CaptureOverlayController.fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.ignoresMouseEvents = false
        })
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Actions

    @objc private func primaryClicked() {
        onPrimary?()
    }

    @objc private func closeClicked() {
        onCancel?()
    }

    @objc private func toggleCursor() {
        AppPreferences.showsCursor.toggle()
        optionsButton.menu = makeOptionsMenu()
    }

    @objc private func saveLocationChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let location = AppPreferences.SaveLocation(rawValue: raw)
        else { return }
        if location == .folder {
            /* Picking a folder needs a real panel; the overlay stays up but
               the panel is a regular window so it lands above it. */
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.canCreateDirectories = true
            open.prompt = L("Choose")
            open.message = L("Choose where captures are saved.")
            open.directoryURL = AppPreferences.saveFolder ?? AppPreferences.desktopDirectory
            open.level = CaptureLevels.toolbar
            if open.runModal() == .OK, let url = open.url {
                AppPreferences.saveFolder = url
                AppPreferences.saveLocation = .folder
            }
        } else {
            AppPreferences.saveLocation = location
        }
        optionsButton.menu = makeOptionsMenu()
    }

    @objc private func timerChosen(_ sender: NSMenuItem) {
        AppPreferences.timerSeconds = sender.tag
        optionsButton.menu = makeOptionsMenu()
    }
}

/* The bar's content: the pointer over it is the arrow. The overlay owns the
   crosshair and the bar is a non-key panel, so without a tracking area of
   its own nothing would reset the cursor when the pointer crosses onto it. */
private final class ArrowCursorView: NSView {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
}

/* Three symbol segments in a rounded track, one of them highlighted, like
   the mode groups of the system's capture bar. Hand-drawn because
   NSSegmentedControl's large style changed its frame and its drawing with
   the selection, which shifted the whole bar whenever the mode moved from
   one group to the other. Here the frame is the drawing, always. */
final class ModeGroupControl: NSView {
    var onSelect: ((Int) -> Void)?
    var selectedIndex: Int? {
        didSet { if selectedIndex != oldValue { needsDisplay = true } }
    }

    private let images: [NSImage]
    /* addToolTip does not retain its owner; a temporary string there was
       freed before the tooltip timer fired and crashed inside
       NSToolTipManager. These keep the owners alive for the view's life. */
    private let toolTipOwners: [NSString]
    private static let segmentWidth: CGFloat = 40
    private static let height: CGFloat = 28
    private static let inset: CGFloat = 2

    init(images: [NSImage], toolTips: [String]) {
        self.images = images
        toolTipOwners = toolTips.map { $0 as NSString }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.segmentWidth * CGFloat(images.count) + Self.inset * 2, height: Self.height))
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        for (index, owner) in toolTipOwners.enumerated() {
            addToolTip(segmentRect(index), owner: owner, userData: nil)
        }
        setAccessibilityRole(.radioGroup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.segmentWidth * CGFloat(images.count) + Self.inset * 2, height: Self.height)
    }

    private func segmentRect(_ index: Int) -> NSRect {
        NSRect(
            x: Self.inset + CGFloat(index) * Self.segmentWidth, y: Self.inset,
            width: Self.segmentWidth, height: Self.height - Self.inset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Self.height / 2
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        if let selectedIndex {
            let pill = segmentRect(selectedIndex)
            NSColor.labelColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        }

        /* Dividers between segments, except beside the highlighted one. */
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        for index in 1..<images.count where index != selectedIndex && index - 1 != selectedIndex {
            let x = Self.inset + CGFloat(index) * Self.segmentWidth
            NSRect(x: x - 0.5, y: bounds.midY - 8, width: 1, height: 16).fill()
        }

        for (index, image) in images.enumerated() {
            let rect = segmentRect(index)
            let size = image.size
            image.draw(
                in: NSRect(
                    x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded(),
                    width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = (0..<images.count).first(where: { segmentRect($0).insetBy(dx: -Self.inset, dy: -Self.inset).contains(point) })
        else { return }
        selectedIndex = index
        onSelect?(index)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /* A plain NSView lets a movable-by-background window start dragging on
       press; this one is a control, so a press picks a mode instead. */
    override var mouseDownCanMoveWindow: Bool { false }
}
