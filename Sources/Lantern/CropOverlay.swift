import AppKit

/* Crop mode over the player, as in Photos: the picture with what falls
   outside the crop dimmed, and a frame with handles on its corners and
   edges to drag, or the inside to drag the whole frame. The crop is kept in
   the video's pixels and the frame is worked out from them, so resizing the
   window keeps it on the same part of the picture. Reset, Cancel and Done
   live in the toolbar, where they cover nothing. */
final class CropOverlayView: NSView {
    /// Called as the crop changes while dragging.
    var onChange: ((PixelInsets) -> Void)?
    var onCancel: (() -> Void)?

    private let pixelSize: CGSize
    /// Room left around the picture, where the player draws it smaller.
    private let margin: CGFloat
    private(set) var insets: PixelInsets
    private var drag: (handle: Handle, start: NSPoint, insets: PixelInsets)?

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
    }

    /// The smallest crop, in points on screen, so the handles stay apart.
    private static let minimumSide: CGFloat = 48
    /// How far from a corner or an edge a click still takes it.
    private static let grab: CGFloat = 10

    init(pixelSize: CGSize, insets: PixelInsets, margin: CGFloat) {
        self.pixelSize = pixelSize
        self.insets = insets
        self.margin = margin
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// A handle can be dragged straight away, even in a window in the back.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reset() {
        insets = .zero
        changed()
    }

    /* Esc leaves crop mode as Cancel does. A plain view gets no
       cancelOperation for it (only text views interpret keys), so it is
       caught here. */
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Geometry

    /// Where the player draws the whole picture: fitted, centered, inside the margin.
    private var videoRect: NSRect {
        let room = bounds.insetBy(dx: margin, dy: margin)
        guard pixelSize.width > 0, pixelSize.height > 0, room.width > 0, room.height > 0 else { return room }
        let scale = min(room.width / pixelSize.width, room.height / pixelSize.height)
        let size = NSSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return NSRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Points on screen per video pixel.
    private var scale: CGFloat {
        pixelSize.width > 0 ? videoRect.width / pixelSize.width : 1
    }

    private var cropRect: NSRect {
        let video = videoRect, s = scale
        return NSRect(
            x: video.minX + CGFloat(insets.left) * s, y: video.minY + CGFloat(insets.top) * s,
            width: video.width - CGFloat(insets.left + insets.right) * s,
            height: video.height - CGFloat(insets.top + insets.bottom) * s)
    }

    private func rect(for handle: Handle) -> NSRect {
        let crop = cropRect, g = Self.grab
        let corner = { (x: CGFloat, y: CGFloat) in NSRect(x: x - g, y: y - g, width: g * 2, height: g * 2) }
        switch handle {
        case .topLeft: return corner(crop.minX, crop.minY)
        case .topRight: return corner(crop.maxX, crop.minY)
        case .bottomLeft: return corner(crop.minX, crop.maxY)
        case .bottomRight: return corner(crop.maxX, crop.maxY)
        case .top: return NSRect(x: crop.minX + g, y: crop.minY - g, width: max(crop.width - g * 2, 0), height: g * 2)
        case .bottom: return NSRect(x: crop.minX + g, y: crop.maxY - g, width: max(crop.width - g * 2, 0), height: g * 2)
        case .left: return NSRect(x: crop.minX - g, y: crop.minY + g, width: g * 2, height: max(crop.height - g * 2, 0))
        case .right: return NSRect(x: crop.maxX - g, y: crop.minY + g, width: g * 2, height: max(crop.height - g * 2, 0))
        case .move: return crop.insetBy(dx: g, dy: g)
        }
    }

    private func handle(at point: NSPoint) -> Handle? {
        Handle.allCases.first { rect(for: $0).contains(point) }
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = handle(at: point) else { return }
        drag = (handle, point, insets)
        if handle == .move { NSCursor.closedHand.push() }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = Int(((point.x - drag.start.x) / scale).rounded())
        let dy = Int(((point.y - drag.start.y) / scale).rounded())
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        let minimum = min(max(Int((Self.minimumSide / scale).rounded(.up)), 16), width, height)
        let start = drag.insets
        var next = start
        func clamp(_ value: Int, _ upper: Int) -> Int { min(max(value, 0), max(upper, 0)) }
        switch drag.handle {
        case .move:
            let x = min(max(dx, -start.left), start.right)
            let y = min(max(dy, -start.top), start.bottom)
            next = PixelInsets(top: start.top + y, left: start.left + x, bottom: start.bottom - y, right: start.right - x)
        default:
            if [.left, .topLeft, .bottomLeft].contains(drag.handle) {
                next.left = clamp(start.left + dx, width - start.right - minimum)
            }
            if [.right, .topRight, .bottomRight].contains(drag.handle) {
                next.right = clamp(start.right - dx, width - start.left - minimum)
            }
            if [.top, .topLeft, .topRight].contains(drag.handle) {
                next.top = clamp(start.top + dy, height - start.bottom - minimum)
            }
            if [.bottom, .bottomLeft, .bottomRight].contains(drag.handle) {
                next.bottom = clamp(start.bottom - dy, height - start.top - minimum)
            }
        }
        if next != insets {
            insets = next
            changed()
        }
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    /* Also when crop mode ends mid-drag (Esc with the button held), which
       sends no mouseUp: the closed hand would stay pushed. */
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { endDrag() }
    }

    private func endDrag() {
        if drag?.handle == .move { NSCursor.pop() }
        drag = nil
        needsDisplay = true
    }

    private func changed() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onChange?(insets)
    }

    override func resetCursorRects() {
        let cursors: [(Handle, NSCursor)] = [
            (.move, .openHand),
            (.top, .frameResize(position: .top, directions: .all)),
            (.bottom, .frameResize(position: .bottom, directions: .all)),
            (.left, .frameResize(position: .left, directions: .all)),
            (.right, .frameResize(position: .right, directions: .all)),
            (.topLeft, .frameResize(position: .topLeft, directions: .all)),
            (.topRight, .frameResize(position: .topRight, directions: .all)),
            (.bottomLeft, .frameResize(position: .bottomLeft, directions: .all)),
            (.bottomRight, .frameResize(position: .bottomRight, directions: .all)),
        ]
        for (handle, cursor) in cursors {
            addCursorRect(rect(for: handle), cursor: cursor)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let video = videoRect, crop = cropRect
        let dim = NSBezierPath(rect: video)
        dim.append(NSBezierPath(rect: crop))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        dim.fill()

        /* Thirds while dragging, as Photos shows them. */
        if drag != nil {
            let thirds = NSBezierPath()
            for i in 1...2 {
                let x = crop.minX + crop.width * CGFloat(i) / 3
                let y = crop.minY + crop.height * CGFloat(i) / 3
                thirds.move(to: NSPoint(x: x, y: crop.minY))
                thirds.line(to: NSPoint(x: x, y: crop.maxY))
                thirds.move(to: NSPoint(x: crop.minX, y: y))
                thirds.line(to: NSPoint(x: crop.maxX, y: y))
            }
            thirds.lineWidth = 0.5
            NSColor.white.withAlphaComponent(0.6).setStroke()
            thirds.stroke()
        }

        /* A soft shadow keeps the white frame visible on light pictures. */
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.white.setStroke()
        let frame = NSBezierPath(rect: crop.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        frame.stroke()

        /* Thick corners and short bars at the edges' middles mark what can
           be dragged, drawn just inside the frame. */
        let marks = NSBezierPath()
        let arm = min(20, crop.width / 3, crop.height / 3)
        let inset = crop.insetBy(dx: 1.5, dy: 1.5)
        for (x, y, sx, sy) in [
            (inset.minX, inset.minY, 1.0, 1.0), (inset.maxX, inset.minY, -1.0, 1.0),
            (inset.minX, inset.maxY, 1.0, -1.0), (inset.maxX, inset.maxY, -1.0, -1.0),
        ] {
            marks.move(to: NSPoint(x: x + arm * sx, y: y))
            marks.line(to: NSPoint(x: x, y: y))
            marks.line(to: NSPoint(x: x, y: y + arm * sy))
        }
        let bar = min(20, crop.width / 4, crop.height / 4) / 2
        marks.move(to: NSPoint(x: inset.midX - bar, y: inset.minY))
        marks.line(to: NSPoint(x: inset.midX + bar, y: inset.minY))
        marks.move(to: NSPoint(x: inset.midX - bar, y: inset.maxY))
        marks.line(to: NSPoint(x: inset.midX + bar, y: inset.maxY))
        marks.move(to: NSPoint(x: inset.minX, y: inset.midY - bar))
        marks.line(to: NSPoint(x: inset.minX, y: inset.midY + bar))
        marks.move(to: NSPoint(x: inset.maxX, y: inset.midY - bar))
        marks.line(to: NSPoint(x: inset.maxX, y: inset.midY + bar))
        marks.lineWidth = 3
        marks.lineCapStyle = .butt
        marks.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }
}
