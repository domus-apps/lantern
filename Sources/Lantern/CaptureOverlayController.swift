import AppKit
import ScreenCaptureKit

/* The pick surface: one transparent, nonactivating panel per display at the
   shielding level. What it shows depends on the toolbar's mode — the
   hovered display, the hovered window, or a draggable, resizable selection
   — and Return / Escape are handled here (the toolbar never takes key).
   Lantern's own windows are excluded from every capture by application, so
   nothing here has to be hidden before the shot. */
@MainActor
final class CaptureOverlayController {
    var onPick: ((CaptureTarget) -> Void)?
    var onCancel: (() -> Void)?
    /// Whether the primary action currently has something to act on.
    var onReadinessChange: ((Bool) -> Void)?

    let snapshot: ShareableSnapshot
    private var panels: [OverlayPanel] = []
    private var screenObserver: Any?
    private var mouseMonitor: Any?

    var mode: CaptureMode {
        didSet {
            for panel in panels { panel.overlayView.modeChanged() }
            reportReadiness()
        }
    }

    init(snapshot: ShareableSnapshot, mode: CaptureMode) {
        self.snapshot = snapshot
        self.mode = mode
    }

    /* The primary screen's height, for AppKit ↔ CoreGraphics flips. */
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
    }

    func show() {
        build()
        /* Nothing sets the cursor until the mouse moves, and the panel
           appearing under the pointer resets it to the arrow; set it again
           once the panels are up. (No synthetic mouse events here: posting
           them needs the "Device Control and Data Access" permission, and
           with Lantern active for the picker they are not needed.) */
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.panels.isEmpty else { return }
                self.panels.first { $0.overlayView.isHovered }?.overlayView.applyCursor()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            /* Displays coming or going: the snapshot is stale too, so the
               pick is over. */
            Task { @MainActor in self?.onCancel?() }
        }
        /* One place decides the cursor. Cursor rects and cursorUpdate would
           keep re-asserting the key overlay's cursor over everything,
           including the toolbar, so the overlays declare none; this monitor
           sees every mouse event of the (active) app and sets the cursor
           for the window and point under the pointer. */
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.updateCursor(for: event) }
            return event
        }
        reportReadiness()
    }

    private func updateCursor(for event: NSEvent) {
        if let panel = event.window as? OverlayPanel {
            panel.overlayView.applyCursor(at: panel.overlayView.convert(event.locationInWindow, from: nil))
        } else {
            NSCursor.arrow.set()
        }
    }

    static let fadeInDuration = 0.16
    static let fadeOutDuration = 0.12

    private func build() {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen, controller: self)
            panel.overlayView.selection = savedSelection(for: screen)
            panels.append(panel)
            /* A plain fade: the panel's own ordering animation would zoom
               the whole overlay out from the screen's center. */
            panel.alphaValue = 0
            if screen.frame.contains(mouse) {
                panel.makeKeyAndOrderFront(nil)
                panel.overlayView.isHovered = true
                panel.overlayView.applyCursor()
            } else {
                panel.orderFrontRegardless()
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for panel in panels { panel.animator().alphaValue = 1 }
        }
    }

    func dismiss() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        /* Fade out, then tear down. The panels stop taking input at once;
           a capture that follows is unaffected because Lantern's windows
           are excluded from it. */
        let fading = panels
        panels = []
        for panel in fading { panel.ignoresMouseEvents = true }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOutDuration
            for panel in fading { panel.animator().alphaValue = 0 }
        }, completionHandler: {
            for panel in fading {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
        NSCursor.arrow.set()
    }

    // MARK: - Picking

    /// Return or the toolbar's primary button.
    func confirm() {
        switch mode.scope {
        case .area:
            guard let panel = panels.first(where: { $0.overlayView.selection != nil }),
                let rect = panel.overlayView.selection
            else { return }
            pickArea(rect, on: panel.overlayView)
        case .display:
            guard let panel = panels.first(where: { $0.overlayView.isHovered }) else { return }
            pickDisplay(of: panel.overlayView)
        case .window:
            guard let panel = panels.first(where: { $0.overlayView.hoveredWindow != nil }),
                let window = panel.overlayView.hoveredWindow
            else { return }
            onPick?(.window(window))
        }
    }

    var isReady: Bool {
        switch mode.scope {
        case .area: panels.contains { $0.overlayView.selection != nil }
        case .display: panels.contains { $0.overlayView.isHovered }
        case .window: panels.contains { $0.overlayView.hoveredWindow != nil }
        }
    }

    fileprivate func reportReadiness() {
        onReadinessChange?(isReady)
    }

    fileprivate func pickDisplay(of view: OverlayView) {
        guard let display = snapshot.display(for: view.screen) else { return }
        onPick?(.display(display))
    }

    fileprivate func pickArea(_ rect: CGRect, on view: OverlayView) {
        guard let display = snapshot.display(for: view.screen) else { return }
        let global = rect.offsetBy(dx: view.screen.frame.minX, dy: view.screen.frame.minY)
        let local = CaptureGeometry.displayLocalRect(fromAppKit: global, screenFrame: view.screen.frame)
        saveSelection(rect, for: view.screen)
        onPick?(.area(display: display, rect: local.integral))
    }

    fileprivate func hoverChanged(to view: OverlayView) {
        for panel in panels where panel.overlayView !== view {
            panel.overlayView.isHovered = false
            panel.overlayView.hoveredWindow = nil
        }
        view.isHovered = true
        /* Key follows the pointer: Return and Escape work on whichever
           display the pointer is on, and a click there is never spent on
           making the panel key. */
        if let panel = view.window, !panel.isKeyWindow {
            panel.makeKey()
        }
        reportReadiness()
    }

    /* The frontmost window under the mouse, in the view's coordinates. */
    fileprivate func window(under viewPoint: CGPoint, in view: OverlayView) -> (SCWindow, CGRect)? {
        let global = CGPoint(x: viewPoint.x + view.screen.frame.minX, y: viewPoint.y + view.screen.frame.minY)
        let cgPoint = CaptureGeometry.cgPoint(fromAppKit: global, primaryScreenHeight: Self.primaryScreenHeight)
        guard let window = snapshot.window(under: cgPoint) else { return nil }
        let appKit = CaptureGeometry.appKitRect(fromCG: window.frame, primaryScreenHeight: Self.primaryScreenHeight)
        return (window, appKit.offsetBy(dx: -view.screen.frame.minX, dy: -view.screen.frame.minY))
    }

    /* A second area selection would be confusing: starting one on a screen
       clears the others. */
    fileprivate func selectionStarted(on view: OverlayView) {
        for panel in panels where panel.overlayView !== view {
            panel.overlayView.selection = nil
        }
    }

    /* Escape backs out one level at a time: an area selection first, then
       the picker itself. */
    fileprivate func cancel() {
        let selected = panels.filter { $0.overlayView.selection != nil }
        if mode.scope == .area, !selected.isEmpty {
            for panel in selected {
                panel.overlayView.selection = nil
            }
            reportReadiness()
            return
        }
        onCancel?()
    }

    // MARK: - Remembered selection

    private func selectionKey(for screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return "pref.lastSelection.\(number)"
    }

    private func savedSelection(for screen: NSScreen) -> CGRect? {
        guard let string = UserDefaults.standard.string(forKey: selectionKey(for: screen)) else { return nil }
        let rect = NSRectFromString(string)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        guard rect.width >= 4, rect.height >= 4, bounds.contains(rect) else { return nil }
        return rect
    }

    private func saveSelection(_ rect: CGRect, for screen: NSScreen) {
        UserDefaults.standard.set(NSStringFromRect(rect), forKey: selectionKey(for: screen))
    }
}

// MARK: - Panel

private final class OverlayPanel: NSPanel {
    let overlayView: OverlayView
    private weak var controller: CaptureOverlayController?

    init(screen: NSScreen, controller: CaptureOverlayController) {
        self.controller = controller
        overlayView = OverlayView(screen: screen, controller: controller)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        level = CaptureLevels.overlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53:  // Escape
            controller?.cancel()
        case 36, 76:  // Return, keypad Enter
            controller?.confirm()
        default:
            break
        }
    }

    override func becomeKey() {
        super.becomeKey()
        if overlayView.isHovered { overlayView.applyCursor() }
    }
}

// MARK: - View

private final class OverlayView: NSView {
    let screen: NSScreen
    private weak var controller: CaptureOverlayController?

    var isHovered = false { didSet { needsDisplay = true } }
    var hoveredWindow: SCWindow?
    private var hoveredWindowRect: CGRect? { didSet { needsDisplay = true } }
    var selection: CGRect? {
        didSet {
            needsDisplay = true
            controller?.reportReadiness()
        }
    }

    private enum Drag {
        case creating(anchor: CGPoint)
        case moving(offset: CGPoint)
        case resizing(handle: Int, anchor: CGRect)
    }
    private var drag: Drag?
    private var trackingArea: NSTrackingArea?

    private static let handleSize: CGFloat = 8
    private static let handleHitSlop: CGFloat = 7
    private static let dimAlpha: CGFloat = 0.38

    init(screen: NSScreen, controller: CaptureOverlayController) {
        self.screen = screen
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    /* A click on a non-key overlay must start the drag, not just make the
       window key. */
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var mode: CaptureMode { controller?.mode ?? CaptureMode(kind: .image, scope: .area) }

    func modeChanged() {
        hoveredWindow = nil
        hoveredWindowRect = nil
        drag = nil
        if mode.scope == .window, isHovered, let window = self.window {
            let point = window.mouseLocationOutsideOfEventStream
            updateHoveredWindow(at: point)
        }
        if isHovered { applyCursor() }
        needsDisplay = true
    }

    /* Cursor rects are honored only in the key window, so the overlays on
       the other displays (and this one, whenever key status moves) would
       fall back to the arrow. Set the cursor directly from the tracking
       events instead; the toolbar covering part of the view fires
       mouseExited, which restores the arrow over its buttons. */
    private var cursor: NSCursor {
        guard let window else { return mode.scope == .area ? .crosshair : Cursors.camera }
        return cursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /* Like the system tool: a hand over the selection (closed while it is
       being moved), directional resize arrows on the handles, the crosshair
       everywhere else in area mode; the plain arrow when picking a display
       or a window. A drag in progress keeps its cursor even when the
       pointer runs ahead of the handle. Display and window picking use the
       camera, like the system tool. */
    private func cursor(at point: CGPoint) -> NSCursor {
        guard let controller else { return .arrow }
        guard controller.mode.scope == .area else { return Cursors.camera }
        switch drag {
        case .moving: return .closedHand
        case .resizing(let handle, _): return Self.resizeCursor(handle: handle)
        case .creating: return .crosshair
        case nil: break
        }
        guard let selection else { return .crosshair }
        if let handle = handleIndex(at: point, of: selection) {
            return Self.resizeCursor(handle: handle)
        }
        if selection.contains(point) { return .openHand }
        return .crosshair
    }

    private static func resizeCursor(handle: Int) -> NSCursor {
        let positions: [NSCursor.FrameResizePosition] = [
            .bottomLeft, .bottomRight, .topRight, .topLeft, .bottom, .right, .top, .left,
        ]
        return .frameResize(position: positions[handle], directions: .all)
    }

    /* Sets this overlay's cursor only if the pointer is really over this
       overlay: at picker open and on mode changes the pointer may be on the
       toolbar (or another display), and the overlay's crosshair or camera
       would otherwise sit over the controls until the next mouse move. */
    func applyCursor() {
        let under = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard let window, under == window.windowNumber else {
            if under != 0 { NSCursor.arrow.set() }
            return
        }
        cursor.set()
    }

    func applyCursor(at point: CGPoint) {
        cursor(at: point).set()
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.hoverChanged(to: self)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredWindow = nil
        hoveredWindowRect = nil
    }

    override func mouseMoved(with event: NSEvent) {
        if !isHovered { controller?.hoverChanged(to: self) }
        if mode.scope == .window {
            updateHoveredWindow(at: convert(event.locationInWindow, from: nil))
        }
    }

    private func updateHoveredWindow(at point: CGPoint) {
        if let (window, rect) = controller?.window(under: point, in: self) {
            if window.windowID != hoveredWindow?.windowID {
                hoveredWindow = window
                hoveredWindowRect = rect
                controller?.reportReadiness()
            }
        } else if hoveredWindow != nil {
            hoveredWindow = nil
            hoveredWindowRect = nil
            controller?.reportReadiness()
        }
    }


    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch mode.scope {
        case .display:
            controller?.pickDisplay(of: self)
        case .window:
            updateHoveredWindow(at: point)
            if let hoveredWindow {
                controller?.onPick?(.window(hoveredWindow))
            }
        case .area:
            if let selection {
                if let handle = handleIndex(at: point, of: selection) {
                    drag = .resizing(handle: handle, anchor: selection)
                    applyCursor()
                    return
                }
                if selection.contains(point) {
                    drag = .moving(offset: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY))
                    applyCursor()
                    return
                }
            }
            controller?.selectionStarted(on: self)
            drag = .creating(anchor: point)
            selection = CGRect(origin: point, size: .zero)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode.scope == .area, let drag else { return }
        let point = clamp(convert(event.locationInWindow, from: nil))
        switch drag {
        case .creating(let anchor):
            selection = CGRect(
                x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        case .moving(let offset):
            guard var rect = selection else { return }
            rect.origin = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
            rect.origin.x = min(max(rect.origin.x, 0), bounds.width - rect.width)
            rect.origin.y = min(max(rect.origin.y, 0), bounds.height - rect.height)
            selection = rect
        case .resizing(let handle, let anchor):
            selection = Self.resized(anchor, handle: handle, to: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard mode.scope == .area, let finished = drag else { return }
        drag = nil
        if let rect = selection {
            if rect.width < 4 || rect.height < 4 {
                selection = nil
            } else if case .moving = finished {
                /* A move keeps its exact size: only the origin is snapped.
                   (`integral` would round the edges outward and grow the
                   selection by up to a point per side on every move.) */
                selection = CGRect(
                    x: rect.minX.rounded(), y: rect.minY.rounded(),
                    width: rect.width, height: rect.height)
            } else {
                selection = Self.snapped(rect)
            }
        }
        applyCursor()
    }

    /* Edges rounded to the nearest point, never outward. */
    static func snapped(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded(), maxX = rect.maxX.rounded()
        let minY = rect.minY.rounded(), maxY = rect.maxY.rounded()
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    /* Handles: 0–3 corners (BL, BR, TR, TL), 4–7 edges (bottom, right, top, left). */
    private static func handleCenters(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
        ]
    }

    private func handleIndex(at point: CGPoint, of rect: CGRect) -> Int? {
        Self.handleCenters(of: rect).firstIndex {
            abs($0.x - point.x) <= Self.handleHitSlop && abs($0.y - point.y) <= Self.handleHitSlop
        }
    }

    static func resized(_ rect: CGRect, handle: Int, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case 0: minX = point.x; minY = point.y
        case 1: maxX = point.x; minY = point.y
        case 2: maxX = point.x; maxY = point.y
        case 3: minX = point.x; maxY = point.y
        case 4: minY = point.y
        case 5: maxX = point.x
        case 6: maxY = point.y
        case 7: minX = point.x
        default: break
        }
        return CGRect(
            x: min(minX, maxX), y: min(minY, maxY),
            width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        /* A non-opaque window owns the pointer only where its pixels have
           nonzero alpha: fully transparent spots (the selection hole, the
           hovered window, an undimmed display) would hand cursor and clicks
           to the app underneath. An imperceptible base fill keeps every
           pixel ours. */
        NSColor.black.withAlphaComponent(0.02).setFill()
        bounds.fill()

        let hole: CGRect?
        switch mode.scope {
        case .display: hole = isHovered ? bounds : nil
        case .window: hole = hoveredWindowRect
        case .area: hole = selection
        }

        /* Dim everything but the hole; window mode dims nothing and tints
           the hovered window instead, like the system tool. */
        if mode.scope == .area {
            let dim = NSBezierPath(rect: bounds)
            if let hole {
                dim.appendRect(hole)
                dim.windingRule = .evenOdd
            }
            NSColor.black.withAlphaComponent(Self.dimAlpha).setFill()
            dim.fill()
        } else if mode.scope == .display, !isHovered {
            NSColor.black.withAlphaComponent(Self.dimAlpha).setFill()
            bounds.fill()
        }

        switch mode.scope {
        case .display:
            if isHovered {
                drawHint(mode.kind == .image ? L("Click to capture this screen") : L("Click to record this screen"))
            }
        case .window:
            if let rect = hoveredWindowRect {
                NSColor.systemBlue.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            } else if isHovered {
                drawHint(mode.kind == .image ? L("Click a window to capture it") : L("Click a window to record it"))
            }
        case .area:
            if let rect = selection {
                drawSelection(rect)
            } else if isHovered {
                drawHint(L("Drag to select an area"))
            }
        }
    }

    private func drawSelection(_ rect: CGRect) {
        /* Stroked on the edge itself (half in, half out): the line's center
           and the handle centers then coincide by construction, whichever
           edge you look at. The rect is integral, so at 2x this is crisp. */
        let border = NSBezierPath(rect: rect)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.lineWidth = 1
        border.stroke()

        if drag == nil || { if case .creating = drag! { return false } else { return true } }() {
            for center in Self.handleCenters(of: rect) {
                let handle = NSRect(
                    x: center.x - Self.handleSize / 2, y: center.y - Self.handleSize / 2,
                    width: Self.handleSize, height: Self.handleSize)
                let path = NSBezierPath(ovalIn: handle)
                NSColor.white.setFill()
                path.fill()
                NSColor.black.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        /* Size readout in points, tucked below the selection (above it when
           there is no room). */
        let scale = screen.backingScaleFactor
        let text = NSAttributedString(
            string: "\(Int(rect.width * scale)) × \(Int(rect.height * scale))",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ])
        let size = text.size()
        let pad: CGFloat = 6
        let pillSize = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)
        /* Below the selection's bottom-right, else above it, else inside its
           bottom-right corner (a selection that fills the display has no
           room outside). Kept on screen horizontally either way. */
        let candidates = [
            CGPoint(x: rect.maxX - pillSize.width, y: rect.minY - pillSize.height - 6),
            CGPoint(x: rect.maxX - pillSize.width, y: rect.maxY + 6),
            CGPoint(x: rect.maxX - pillSize.width - 8, y: rect.minY + 8),
        ]
        var origin = candidates.first { $0.y >= 4 && $0.y + pillSize.height <= bounds.height - 4 } ?? candidates[2]
        origin.x = min(max(origin.x, 4), bounds.width - pillSize.width - 4)
        let pill = NSRect(origin: origin, size: pillSize)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: pill.minX + pad, y: pill.minY + pad))
    }

    private func drawHint(_ string: String) {
        let text = NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ])
        let size = text.size()
        let pad: CGFloat = 10
        let pill = NSRect(
            x: (bounds.midX - size.width / 2 - pad).rounded(),
            y: screen.visibleFrame.maxY - screen.frame.minY - 60 - size.height,
            width: size.width + pad * 2, height: size.height + pad * 1.4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + pad, y: pill.minY + pad * 0.7))
    }
}

// MARK: - Recording frame

/* While an area records, a thin frame marks it. Click-through, above other
   windows, and — like every Lantern window — excluded from the recording. */
@MainActor
final class RecordingFrameWindow {
    private let panel: NSPanel

    /// `rect` in AppKit global coordinates.
    init(rect: CGRect) {
        let inset: CGFloat = 3
        let frame = rect.insetBy(dx: -inset, dy: -inset)
        panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = FrameView(frame: NSRect(origin: .zero, size: frame.size))
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    private final class FrameView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.stroke()
            let dashed = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            dashed.lineWidth = 1.5
            dashed.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            dashed.stroke()
        }
    }
}

/* The camera cursor of the system's capture tool has no public constant;
   this one is the camera symbol with a light outline so it reads on any
   backdrop, hot spot at its center. */
enum Cursors {
    static let camera: NSCursor = {
        let size = NSSize(width: 28, height: 28)
        let image = NSImage(size: size, flipped: false) { rect in
            guard
                let glyph = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))
            else { return false }
            let glyphSize = glyph.size
            let origin = NSPoint(
                x: (rect.midX - glyphSize.width / 2).rounded(), y: (rect.midY - glyphSize.height / 2).rounded())
            let glyphRect = NSRect(origin: origin, size: glyphSize)
            /* Outline: the glyph stamped around itself in white, then the
               dark glyph on top. */
            for dx in [-1.5, 0, 1.5] as [CGFloat] {
                for dy in [-1.5, 0, 1.5] as [CGFloat] where dx != 0 || dy != 0 {
                    glyph.tinted(.white).draw(in: glyphRect.offsetBy(dx: dx, dy: dy))
                }
            }
            glyph.tinted(NSColor(white: 0.12, alpha: 1)).draw(in: glyphRect)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 14, y: 14))
    }()
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
